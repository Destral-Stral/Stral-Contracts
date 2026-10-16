// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { SwapModule } from "src/swap/SwapModule.sol";
// Libs
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";
import { Address } from "@openzeppelin/contracts-5/utils/Address.sol";
import { PasskeySignature } from "src/libs/PasskeySignature.sol";
// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { ISmartWalletFactory } from "src/interfaces/ISmartWalletFactory.sol";
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";
import { IStaking } from "src/interfaces/IStaking.sol";

/// @title SmartWallet
/// @notice A smart contract wallet with multi-signer authentication (EOA wallets + passkeys),
///         a recipient whitelist for withdrawals, and routing of transfers to a coordinator-
///         managed strategy address.
///
///         Wallet addresses are deterministic and depend only on (factory, id) — not on the
///         owners, which are injected at initialization via the factory's Parameters callback.
/// @dev Deployed as a BeaconProxy pointing to a shared implementation. The implementation's
///      constructor only disables initializers; all setup runs through `initialize` via the
///      proxy's delegatecall, where `msg.sender` is the factory that created the proxy.
///
///      Owner management and signature verification are handled by {MultiSignerAuth};
///      aggregator token swaps by {SwapModule} (both inherited, the module is stateless).
///      EIP-712 domain is scoped to the proxy's address, preventing cross-wallet replay.
contract SmartWallet is SwapModule {
  using SafeERC20 for IERC20;

  // ====== ERRORS ====== //

  error TokenNotAllowed(address token);
  error StrategyNotSet();
  error StakingNotConfigured();
  error NotWhitelisted(address recipient);
  error WithdrawalDelayNotMet(uint256 availableAt);
  error NoInitialOwner();

  // ====== EVENTS ====== //

  event WhitelistAdded(address indexed recipient, uint256 timestamp);
  event WhitelistRemoved(address indexed recipient);
  event AssetsWithdrawn(
    address indexed to,
    address indexed assets,
    uint256 amount
  );
  event AssetsTransferred(
    address indexed assets,
    uint256 amount,
    address indexed strategy
  );
  event Received(address indexed from, uint256 amount);
  event Staked(uint256 amount, address indexed destination);
  event Unstaked(uint256 amount, address indexed destination);

  // ====== STORAGE ====== //

  /// @notice Address of the SmartWalletFactory
  ISmartWalletFactory public factory;
  /// @notice Address of the SmartWalletCoordinator
  ISmartWalletCoordinator public coordinator;

  /// @notice Whitelist of addresses that may receive withdrawals from this wallet.
  /// @dev Sentinel values:
  ///        0  — not whitelisted
  ///        1  — legacy immediate entry (never subject to delay)
  ///        >1 — block.timestamp when added; delay from coordinator applies before withdrawals
  mapping(address => uint256) public whitelist;
  address[] private _whitelistAddresses;

  // ====== CONSTRUCTOR ====== //

  /// @dev Disables initializers on the implementation contract so it cannot be initialized
  ///      directly. All initialization must go through a BeaconProxy's delegatecall.
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  // ====== RECEIVE ====== //

  /// @notice Accepts native ETH deposits.
  receive() external payable {
    emit Received(msg.sender, msg.value);
  }

  // ====== INITIALIZER ====== //

  /// @dev Called once via BeaconProxy's constructor delegatecall. `msg.sender` is the factory,
  ///      so all callbacks resolve to the factory's transient storage and public variables.
  ///      Owner config is kept out of the proxy's init code, leaving the CREATE2 address
  ///      dependent only on (factory, id).
  ///
  ///      Ownership config based on `params.passkeyAlgo`:
  ///        None  — wallet owner only (wallet address required)
  ///        ES256 — P-256 passkey (qx, qy), optionally alongside a wallet owner
  ///        RS256 — RSA passkey (n, e), optionally alongside a wallet owner
  ///
  ///      Reverts with {NoInitialOwner} if the config would leave the wallet without a
  ///      usable owner: no wallet address and either no passkey or an empty passkey key.
  function initialize() public initializer {
    __MultiSignerAuth_init("SmartWallet", "1");

    factory = ISmartWalletFactory(msg.sender);
    coordinator = ISmartWalletCoordinator(factory.coordinator());

    ISmartWalletFactory.Parameters memory params = factory
      .parameters();

    bool hasWallet = params.wallet != address(0);
    if (hasWallet) {
      // @dev This is either the user's wallet or their backup seed
      _registerWalletOwner(params.wallet);
    }

    if (params.passkeyAlgo == ISmartWalletFactory.PasskeyAlgo.ES256) {
      if (!hasWallet && params.qx == 0) revert NoInitialOwner();
      _registerES256Owner(
        params.credentialId,
        PasskeySignature.ES256PublicKey({
          qx: params.qx,
          qy: params.qy
        })
      );
    } else if (
      params.passkeyAlgo == ISmartWalletFactory.PasskeyAlgo.RS256
    ) {
      if (!hasWallet && params.n.length == 0) revert NoInitialOwner();
      _registerRS256Owner(
        params.credentialId,
        RS256PublicKey({ n: params.n, e: params.e })
      );
    } else if (!hasWallet) {
      revert NoInitialOwner();
    }
  }

  // ====== INTERNALS ====== //

  /// @dev Coordinator accessor for {SwapModule}, which is stateless by design.
  function _coordinator()
    internal
    view
    override
    returns (ISmartWalletCoordinator)
  {
    return coordinator;
  }

  /// @dev EIP-712 struct hash for {addToWhitelist}.
  function _hashAddToWhitelist(
    address recipient,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"
          ),
          recipient,
          nonce,
          deadline
        )
      );
  }

  /// @dev EIP-712 struct hash for {removeFromWhitelist}.
  function _hashRemoveFromWhitelist(
    address recipient,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "RemoveFromWhitelist(address recipient,uint256 nonce,uint256 deadline)"
          ),
          recipient,
          nonce,
          deadline
        )
      );
  }

  /// @dev EIP-712 struct hash for {withdrawAssets}.
  function _hashWithdrawAssets(
    address to,
    address assets,
    uint256 amount,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "WithdrawAssets(address to,address assets,uint256 amount,uint256 nonce,uint256 deadline)"
          ),
          to,
          assets,
          amount,
          nonce,
          deadline
        )
      );
  }

  /// @dev EIP-712 struct hash for {transferAssets}.
  function _hashTransferAssets(
    address assets,
    uint256 amount,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "TransferAssets(address assets,uint256 amount,uint256 nonce,uint256 deadline)"
          ),
          assets,
          amount,
          nonce,
          deadline
        )
      );
  }

  /// @dev EIP-712 struct hash for {stake}.
  function _hashStake(
    uint256 amount,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "Stake(uint256 amount,uint256 nonce,uint256 deadline)"
          ),
          amount,
          nonce,
          deadline
        )
      );
  }

  /// @dev EIP-712 struct hash for {unstake}.
  function _hashUnstake(
    uint256 amount,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "Unstake(uint256 amount,uint256 nonce,uint256 deadline)"
          ),
          amount,
          nonce,
          deadline
        )
      );
  }

  // ====== VIEW FUNCTIONS ====== //

  /// @notice Returns all whitelisted addresses and their corresponding timestamps.
  /// @dev Sentinel 1 = immediate legacy entry; >1 = block.timestamp when added (delay applies).
  function getWhitelist()
    external
    view
    returns (address[] memory recipients, uint256[] memory timestamps)
  {
    uint256 len = _whitelistAddresses.length;
    recipients = new address[](len);
    timestamps = new uint256[](len);
    for (uint256 i = 0; i < len; i++) {
      recipients[i] = _whitelistAddresses[i];
      timestamps[i] = whitelist[_whitelistAddresses[i]];
    }
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Adds a recipient to the withdrawal whitelist.
  /// @dev The coordinator's `withdrawalDelay` must pass before the recipient can receive funds.
  /// @param recipient Address to whitelist.
  /// @param deadline  Timestamp after which a signed authorization is no longer valid.
  /// @param auth      Owner credentials.
  function addToWhitelist(
    address recipient,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(auth, _hashAddToWhitelist(recipient, deadline), deadline)
  {
    if (whitelist[recipient] == 0)
      _whitelistAddresses.push(recipient);

    whitelist[recipient] = block.timestamp;
    emit WhitelistAdded(recipient, block.timestamp);
  }

  /// @notice Removes a recipient from the withdrawal whitelist.
  /// @param recipient Address to remove.
  /// @param deadline  Timestamp after which a signed authorization is no longer valid.
  /// @param auth      Owner credentials.
  function removeFromWhitelist(
    address recipient,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      _hashRemoveFromWhitelist(recipient, deadline),
      deadline
    )
  {
    if (whitelist[recipient] != 0) {
      uint256 len = _whitelistAddresses.length;
      for (uint256 i = 0; i < len; i++) {
        if (_whitelistAddresses[i] == recipient) {
          _whitelistAddresses[i] = _whitelistAddresses[len - 1];
          _whitelistAddresses.pop();
          break;
        }
      }
    }

    delete whitelist[recipient];
    emit WhitelistRemoved(recipient);
  }

  /// @notice Withdraws assets to a whitelisted recipient.
  /// @dev Reverts if `to` is not whitelisted or if the coordinator's withdrawal delay has
  ///      not elapsed since the address was added. Only legacy immediate entries (sentinel 1)
  ///      are exempt from the delay. Not gated by the coordinator's token allowlist, so any
  ///      asset held by the wallet can always be withdrawn.
  /// @param to       Recipient address. Must be in the whitelist.
  /// @param assets   ERC-20 token address, or the zero address for native ETH.
  /// @param amount   Amount to withdraw.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Owner credentials.
  function withdrawAssets(
    address to,
    address assets,
    uint256 amount,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      _hashWithdrawAssets(to, assets, amount, deadline),
      deadline
    )
  {
    uint256 addedAt = whitelist[to];
    if (addedAt == 0) revert NotWhitelisted(to);
    if (addedAt > 1) {
      uint256 availableAt = addedAt + coordinator.withdrawalDelay();
      if (block.timestamp < availableAt)
        revert WithdrawalDelayNotMet(availableAt);
    }

    if (assets == address(0)) Address.sendValue(payable(to), amount);
    else IERC20(assets).safeTransfer(to, amount);
    emit AssetsWithdrawn(to, assets, amount);
  }

  /// @notice Transfers assets to the strategy address set in the coordinator.
  /// @dev The destination is resolved on each call so a coordinator update reroutes all wallets.
  ///      Native ETH (the zero address) is first wrapped into the coordinator's WETH, which is
  ///      what the strategy receives and must be on the token allowlist.
  /// @param assets   ERC-20 token address, or the zero address for native ETH.
  /// @param amount   Amount to transfer.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Owner credentials.
  function transferAssets(
    address assets,
    uint256 amount,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      _hashTransferAssets(assets, amount, deadline),
      deadline
    )
  {
    if (assets == address(0)) assets = _wrapEth(coordinator, amount);
    if (!coordinator.isTokenAllowed(assets))
      revert TokenNotAllowed(assets);
    if (coordinator.isBlocked(address(this))) revert WalletBlocked();
    address strategy = coordinator.strategyAddress();
    if (strategy == address(0)) revert StrategyNotSet();

    IERC20(assets).safeTransfer(strategy, amount);
    emit AssetsTransferred(assets, amount, strategy);
  }

  /// @notice Stakes platform tokens to the coordinator's staking destination.
  /// @dev Token and destination are read from the coordinator on each call. Reverts if either
  ///      is unset. The stakingToken is the only token transferable through this path.
  /// @param amount   Amount to stake.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Owner credentials.
  function stake(
    uint256 amount,
    uint256 deadline,
    Auth calldata auth
  ) external onlyUser(auth, _hashStake(amount, deadline), deadline) {
    IERC20 token = coordinator.stakingToken();
    address destination = coordinator.stakingContract();

    if (address(token) == address(0)) revert StakingNotConfigured();
    if (destination == address(0)) revert StakingNotConfigured();

    token.forceApprove(destination, amount);

    IStaking(destination).stake(amount);
    emit Staked(amount, destination);
  }

  /// @notice Unstakes platform tokens from the coordinator's staking contract.
  /// @dev The staking contract claims from vested positions first, then falls back to
  ///      unlocked direct staking positions. Claimed tokens are transferred back to
  ///      this wallet by the staking contract.
  /// @param amount   Amount to unstake.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Owner credentials.
  function unstake(
    uint256 amount,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(auth, _hashUnstake(amount, deadline), deadline)
  {
    IERC20 token = coordinator.stakingToken();
    address destination = coordinator.stakingContract();

    if (address(token) == address(0)) revert StakingNotConfigured();
    if (destination == address(0)) revert StakingNotConfigured();

    IStaking(destination).unstake(amount);
    emit Unstaked(amount, destination);
  }
}
