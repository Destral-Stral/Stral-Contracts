// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";

/// @title SmartWalletCoordinator
/// @notice Central authority for the Palantex smart wallet system. Holds system-wide
///         configuration (strategy address, withdrawal delay) and exposes `owner()` as
///         the single admin identity — the factory delegates its admin checks here.
/// @dev Deployed as a transparent proxy. The deployer becomes `owner()` via `__Ownable_init`.
///      `factory` is set in a post-deploy step by the deployment script so that both
///      contracts can reference each other after they exist.
contract SmartWalletCoordinator is Initializable, OwnableUpgradeable {
  /// @notice Optional initial configuration applied during deployment.
  /// @dev Zero address / zero delay fields are left unset.
  struct Setup {
    address owner;
    address strategyAddress;
    uint256 withdrawalDelay;
    address[] allowedTokens;
    address stakingToken;
    address stakingContract;
    address vestingContract;
    address relayer;
  }

  // ====== STORAGE ====== //

  /// @notice Address of the SmartWalletFactory proxy.
  /// @dev Set by the deployment script after the factory is deployed, and updatable by the
  ///      owner via `setFactory`. Kept as an on-chain reference to the current factory.
  address public factory;

  /// @notice Contract for all `transferAssets` calls across every SmartWallet.
  /// @dev Typically a yield strategy or protocol vault. Wallets read this on each transfer
  ///      so a single update here reroutes the entire fleet.
  address public strategyAddress;

  /// @notice Minimum time (in seconds) that must pass after a recipient is added to a
  ///         wallet's whitelist before that recipient can receive withdrawals.
  /// @dev Defaults to 24 hours. Gives owners a window to revoke a mistaken whitelist entry
  ///      before funds can flow out.
  uint256 public withdrawalDelay;

  /// @dev Set of wallet addresses blocked from calling `transferAssets` to the strategy.
  mapping(address => bool) public blocked;
  address[] private _blockedList;

  /// @dev Tokens permitted for wallet transfers to the strategy and swaps. Withdrawals are
  ///      not gated. The zero address stands for native ETH.
  mapping(address => bool) public allowedTokens;
  address[] private _allowedTokensList;

  /// @notice The platform token. Only this token may be staked via SmartWallet.stake.
  IERC20 public stakingToken;

  /// @notice Staking contract address — routing target for wallet staking calls and the
  ///         only caller trusted by `VestingDistributor.claimFor`.
  address public stakingContract;

  /// @notice Vesting contract address — resolved by `Staking` for claims and balance reads.
  address public vestingContract;

  /// @notice The only address permitted to deploy wallets through the SmartWalletFactory.
  /// @dev Prevents front-running of counterfactual wallet addresses: wallet addresses depend
  ///      only on (factory, walletId), so deployment must be restricted to a trusted relayer.
  address public relayer;

  /// @notice Shared SwapExecutor contract used by SmartWallet swaps.
  /// @dev Set post-deploy via `setSwapExecutor` (the executor needs this coordinator's
  ///      address at construction, like the factory). Appended last to preserve the
  ///      proxy's storage layout.
  address public swapExecutor;

  /// @notice The chain's WETH contract. Wallets wrap native ETH into it when ETH (the zero
  ///         address) is used in a swap or strategy transfer.
  /// @dev Set post-deploy via `setWeth`. Appended last to preserve the proxy's storage layout.
  address public weth;

  // ====== EVENTS ====== //

  event FactorySet(address indexed factory);
  event StrategyAddressUpdated(address indexed strategyAddress);
  event WithdrawalDelayUpdated(uint256 delay);
  event WalletBlocked(address indexed wallet);
  event WalletUnblocked(address indexed wallet);
  event TokenAllowed(address indexed token);
  event TokenDisallowed(address indexed token);
  event StakingTokenSet(address indexed token);
  event StakingContractSet(address indexed contractAddress);
  event VestingContractSet(address indexed contractAddress);
  event RelayerSet(address indexed relayer);
  event SwapExecutorSet(address indexed swapExecutor);
  event WethSet(address indexed weth);

  // ====== CONSTRUCTOR ====== //

  /// @dev Disables initializers on the implementation contract so it cannot be initialized
  ///      directly. Initialization must happen atomically through the proxy's constructor.
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  // ====== INITIALIZER ====== //

  function initialize(
    Setup calldata setup
  ) public initializer {
    __Ownable_init();
    _applySetup(setup);
  }

  // ====== VIEW FUNCTIONS ====== //

  /// @notice Returns whether a wallet is blocked from sending to the strategy.
  function isBlocked(address wallet) external view returns (bool) {
    return blocked[wallet];
  }

  /// @notice Returns whether a token is on the allowlist for asset movements.
  function isTokenAllowed(
    address token
  ) external view returns (bool) {
    return allowedTokens[token];
  }

  /// @notice Returns all wallets currently blocked from sending to the strategy.
  function getBlockedWallets()
    external
    view
    returns (address[] memory)
  {
    return _blockedList;
  }

  /// @notice Returns all tokens currently on the allowlist.
  function getAllowedTokens()
    external
    view
    returns (address[] memory)
  {
    return _allowedTokensList;
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Sets the authorized factory address.
  /// @dev Called once by the deployment script immediately after the factory is deployed.
  /// @param _factory Address of the SmartWalletFactory proxy.
  function setFactory(address _factory) external onlyOwner {
    factory = _factory;
    emit FactorySet(_factory);
  }

  /// @notice Updates the strategy address that all wallet transfers are routed to.
  /// @param _strategyAddress New strategy contract address.
  function setStrategyAddress(
    address _strategyAddress
  ) public onlyOwner {
    strategyAddress = _strategyAddress;
    emit StrategyAddressUpdated(_strategyAddress);
  }

  /// @notice Updates the withdrawal delay applied to newly whitelisted recipients.
  /// @dev Does not affect recipients already past their delay. Existing immediate-flag
  ///      entries (init-time addresses) are never affected regardless of this value.
  /// @param _withdrawalDelay New delay in seconds.
  function setWithdrawalDelay(
    uint256 _withdrawalDelay
  ) public onlyOwner {
    withdrawalDelay = _withdrawalDelay;
    emit WithdrawalDelayUpdated(_withdrawalDelay);
  }

  /// @notice Blocks a wallet from routing funds to the strategy via `transferAssets`.
  /// @dev Does not affect withdrawals. Intended to freeze a compromised or non-compliant wallet.
  /// @param wallet Address of the SmartWallet proxy to block.
  function blockWallet(address wallet) external onlyOwner {
    if (!blocked[wallet]) _blockedList.push(wallet);
    blocked[wallet] = true;
    emit WalletBlocked(wallet);
  }

  /// @notice Removes a block previously set on a wallet.
  /// @param wallet Address of the SmartWallet proxy to unblock.
  function unblockWallet(address wallet) external onlyOwner {
    if (blocked[wallet]) {
      uint256 len = _blockedList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_blockedList[i] == wallet) {
          _blockedList[i] = _blockedList[len - 1];
          _blockedList.pop();
          break;
        }
      }
    }

    blocked[wallet] = false;
    emit WalletUnblocked(wallet);
  }

  /// @notice Adds a token to the allowlist, enabling it for transfers and swaps.
  /// @param token ERC-20 token address to permit.
  function allowToken(address token) public onlyOwner {
    if (!allowedTokens[token]) _allowedTokensList.push(token);

    allowedTokens[token] = true;
    emit TokenAllowed(token);
  }

  /// @notice Sets the platform token address for staking.
  /// @param token_ Address of the platform ERC-20 token.
  function setStakingToken(address token_) public onlyOwner {
    stakingToken = IERC20(token_);
    emit StakingTokenSet(token_);
  }

  /// @notice Sets the staking contract address for platform transfers.
  /// @param _stakingContract Address that receives staked platform tokens.
  function setStakingContract(
    address _stakingContract
  ) public onlyOwner {
    stakingContract = _stakingContract;
    emit StakingContractSet(_stakingContract);
  }

  /// @notice Sets the vesting contract address for platform vesting operations.
  /// @param _vestingContract Address of the platform vesting contract.
  function setVestingContract(
    address _vestingContract
  ) public onlyOwner {
    vestingContract = _vestingContract;
    emit VestingContractSet(_vestingContract);
  }

  /// @notice Sets the relayer allowed to deploy wallets through the factory.
  /// @param _relayer Address of the trusted relayer wallet.
  function setRelayer(address _relayer) public onlyOwner {
    relayer = _relayer;
    emit RelayerSet(_relayer);
  }

  /// @notice Sets the shared SwapExecutor contract used by SmartWallet swaps.
  /// @param _swapExecutor Address of the SwapExecutor. Zero disables swaps.
  function setSwapExecutor(address _swapExecutor) external onlyOwner {
    swapExecutor = _swapExecutor;
    emit SwapExecutorSet(_swapExecutor);
  }

  /// @notice Sets the chain's WETH contract used to wrap native ETH.
  /// @param _weth Address of the WETH contract. Zero disables ETH wrapping.
  function setWeth(address _weth) external onlyOwner {
    weth = _weth;
    emit WethSet(_weth);
  }

  /// @notice Removes a token from the allowlist.
  /// @param token ERC-20 token address to revoke.
  function disallowToken(address token) external onlyOwner {
    if (allowedTokens[token]) {
      uint256 len = _allowedTokensList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_allowedTokensList[i] == token) {
          _allowedTokensList[i] = _allowedTokensList[len - 1];
          _allowedTokensList.pop();
          break;
        }
      }
    }

    allowedTokens[token] = false;
    emit TokenDisallowed(token);
  }

  function _applySetup(
    Setup calldata setup
  ) private {
    if (setup.strategyAddress != address(0))
      setStrategyAddress(setup.strategyAddress);
    if (setup.withdrawalDelay != 0)
      setWithdrawalDelay(setup.withdrawalDelay);

    uint256 len = setup.allowedTokens.length;
    for (uint256 i = 0; i < len; i++) {
      if (setup.allowedTokens[i] != address(0))
        allowToken(setup.allowedTokens[i]);
    }

    if (setup.stakingToken != address(0))
      setStakingToken(setup.stakingToken);
    if (setup.stakingContract != address(0))
      setStakingContract(setup.stakingContract);
    if (setup.vestingContract != address(0))
      setVestingContract(setup.vestingContract);
    if (setup.relayer != address(0)) setRelayer(setup.relayer);

    if (setup.owner != address(0) && setup.owner != owner())
      _transferOwnership(setup.owner);
  }
}
