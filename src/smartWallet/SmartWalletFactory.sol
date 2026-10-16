// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts-5/proxy/beacon/UpgradeableBeacon.sol";
import { BeaconProxy } from "@openzeppelin/contracts-5/proxy/beacon/BeaconProxy.sol";
// Interfaces
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";
import { ISmartWalletFactory } from "src/interfaces/ISmartWalletFactory.sol";

/// @title SmartWalletFactory
/// @notice Deploys SmartWallet instances at deterministic addresses using CREATE2 + BeaconProxy.
///         All proxies share a single UpgradeableBeacon, allowing the wallet implementation to
///         be upgraded for all wallets in one transaction.
/// @dev Uses the Uniswap V3 Parameters pattern: the BeaconProxy's `initialize()` call carries
///      no arguments — instead the SmartWallet reads owner config from the factory's transient
///      `_parameters` storage during its delegatecall, where msg.sender resolves to this factory.
///
///      Because `initialize()` has no arguments, the `data` passed to BeaconProxy is always
///      the same 4-byte selector. Combined with a fixed beacon address, wallet addresses depend
///      only on (factory, id) regardless of owner or coordinator changes.
///
///      Admin functions are gated by `onlyCoordinatorOwner`, which reads `owner()` from the
///      coordinator rather than maintaining a local owner, keeping authority centralized.
contract SmartWalletFactory is Initializable {
  /// @notice Returned by `getWallets` — pairs a walletId with its deployed wallet address.
  struct WalletEntry {
    bytes32 walletId;
    address wallet;
  }

  /// @notice Calldata struct for `deployWalletWithPasskey`.
  /// @dev `qx`/`qy` are used for ES256; `n`/`e` are used for RS256. Unused fields should be zero/empty.
  struct InitialPasskey {
    ISmartWalletFactory.PasskeyAlgo algo;
    bytes32 credentialId;
    bytes32 qx;
    bytes32 qy;
    bytes n;
    bytes e;
  }

  // ======== ERRORS ======== //

  error NotOwner();
  error NotRelayer();

  // ======== EVENTS ======== //

  event WalletDeployed(
    bytes32 indexed walletId,
    address indexed walletAddress
  );
  event ImplementationUpgraded(address indexed newImplementation);

  // ======== STORAGE ======== //

  /// @notice Address of the SmartWalletCoordinator. Used for admin auth and passed to wallets.
  address public coordinator;

  /// @notice The UpgradeableBeacon that all SmartWallet proxies point to for their implementation.
  /// @dev Owned by this factory (proxy). Call `upgradeTo` to update the implementation for all wallets.
  address public beaconImplementation;

  /// @dev Dead storage. Previous implementations kept the deployment `Parameters` struct here
  ///      (6 slots, always `delete`d after each deployment, so the slots hold zero). The gap
  ///      preserves the slots of the wallet registry below so an already-deployed factory
  ///      proxy can be upgraded in place. Parameters now live in transient storage.
  uint256[6] private __gapParameters;

  /// @dev Base transient-storage slot (EIP-1153) for the abi-encoded deployment parameters.
  ///      Slot holds the blob length; data words follow in consecutive slots. Using transient
  ///      storage instead of regular storage avoids ~20k gas per word on each deployment
  ///      (the RS256 passkey path encodes to a dozen words).
  bytes32 private constant PARAMETERS_TSLOT =
    keccak256("palantex.SmartWalletFactory.parameters");

  /// @notice Maps walletId to the deployed wallet address.
  mapping(bytes32 => address) public walletIdToWallet;

  /// @notice Maps wallet address back to its walletId.
  mapping(address => bytes32) public walletToWalletId;

  /// @dev Ordered list of walletIds for enumeration in `getWallets`.
  bytes32[] private _walletIds;

  // ======== CONSTRUCTOR ======== //

  /// @dev Disables initializers on the implementation contract so it cannot be initialized
  ///      directly. Initialization must happen atomically through the proxy's constructor.
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  // ======== INITIALIZER ======== //

  /// @param _coordinator     Address of the deployed SmartWalletCoordinator proxy.
  /// @param _implementation  Address of the initial SmartWallet implementation contract.
  function initialize(
    address _coordinator,
    address _implementation
  ) public initializer {
    coordinator = _coordinator;
    beaconImplementation = address(
      new UpgradeableBeacon(_implementation, address(this))
    );
  }

  // ======== MODIFIER ======== //

  /// @dev Restricts a function to the owner of the coordinator contract.
  ///      Reads `owner()` on each call — no local state to keep in sync.
  modifier onlyCoordinatorOwner() {
    if (msg.sender != ISmartWalletCoordinator(coordinator).owner())
      revert NotOwner();
    _;
  }

  /// @dev Restricts wallet creation to the trusted relayer registered in the coordinator.
  ///      Wallet addresses depend only on (factory, walletId), so an open deployment path
  ///      would let anyone front-run a counterfactual address with their own owner.
  modifier onlyRelayer() {
    if (msg.sender != ISmartWalletCoordinator(coordinator).relayer())
      revert NotRelayer();
    _;
  }

  // ======== VIEWS ======== //

  /// @notice Returns the current transient deployment parameters.
  /// @dev Only meaningful during a SmartWallet constructor delegatecall. Outside a
  ///      deployment the transient slots are empty and a zeroed struct is returned.
  function parameters()
    external
    view
    returns (ISmartWalletFactory.Parameters memory)
  {
    bytes32 slot = PARAMETERS_TSLOT;
    uint256 len;
    assembly ("memory-safe") {
      len := tload(slot)
    }
    if (len == 0) {
      return
        ISmartWalletFactory.Parameters({
          wallet: address(0),
          passkeyAlgo: ISmartWalletFactory.PasskeyAlgo.None,
          credentialId: 0,
          qx: 0,
          qy: 0,
          n: "",
          e: ""
        });
    }

    bytes memory blob = new bytes(len);
    assembly ("memory-safe") {
      let words := div(add(len, 31), 32)
      for {
        let i := 0
      } lt(i, words) {
        i := add(i, 1)
      } {
        mstore(
          add(blob, add(0x20, mul(i, 0x20))),
          tload(add(add(slot, 1), i))
        )
      }
    }
    return abi.decode(blob, (ISmartWalletFactory.Parameters));
  }

  /// @notice Computes the deterministic address a wallet would be deployed to for a given walletId.
  /// @dev Mirrors the CREATE2 parameters used in `_deployProxy` so callers can predict the address
  ///      before spending gas on deployment.
  /// @param walletId The same salt that would be passed to `deployWallet` / `deployWalletWithPasskey`.
  /// @return The address the BeaconProxy would land at.
  function computeWalletAddress(
    bytes32 walletId
  ) external view returns (address) {
    bytes32 initcodeHash = keccak256(
      abi.encodePacked(
        type(BeaconProxy).creationCode,
        abi.encode(
          beaconImplementation,
          abi.encodeWithSignature("initialize()")
        )
      )
    );
    return address(
      uint160(
        uint256(
          keccak256(
            abi.encodePacked(
              bytes1(0xff),
              address(this),
              walletId,
              initcodeHash
            )
          )
        )
      )
    );
  }

  /// @notice Returns all deployed wallets as (walletId, wallet) pairs.
  /// @dev Unpaginated — may exceed RPC gas caps once the fleet grows large.
  ///      Prefer `getWalletsPage` for off-chain enumeration.
  function getWallets()
    external
    view
    returns (WalletEntry[] memory entries)
  {
    uint256 len = _walletIds.length;
    entries = new WalletEntry[](len);
    for (uint256 i = 0; i < len; i++) {
      bytes32 id = _walletIds[i];
      entries[i] = WalletEntry({ walletId: id, wallet: walletIdToWallet[id] });
    }
  }

  /// @notice Returns a window of deployed wallets as (walletId, wallet) pairs.
  /// @param offset Zero-based index of the first wallet to include.
  /// @param limit  Maximum number of entries to return.
  /// @return entries Requested window of wallet entries.
  /// @return total   Total number of deployed wallets regardless of the window.
  function getWalletsPage(
    uint256 offset,
    uint256 limit
  )
    external
    view
    returns (WalletEntry[] memory entries, uint256 total)
  {
    total = _walletIds.length;
    if (offset >= total) return (new WalletEntry[](0), total);

    uint256 end = limit > total - offset ? total : offset + limit;
    entries = new WalletEntry[](end - offset);
    for (uint256 i = offset; i < end; i++) {
      bytes32 id = _walletIds[i];
      entries[i - offset] = WalletEntry({
        walletId: id,
        wallet: walletIdToWallet[id]
      });
    }
  }

  // ======== CORE FUNCTIONS ======== //

  /// @notice Upgrades the SmartWallet implementation for all existing and future wallets.
  /// @param newImplementation Address of the new SmartWallet implementation contract.
  function upgradeTo(
    address newImplementation
  ) external onlyCoordinatorOwner {
    UpgradeableBeacon(beaconImplementation).upgradeTo(
      newImplementation
    );

    emit ImplementationUpgraded(newImplementation);
  }

  /// @notice Deploys a new SmartWallet with a single EOA owner. Restricted to the relayer.
  /// @param walletId   CREATE2 salt. The wallet address is stable as long as (factory, id) is the same.
  /// @param wallet EOA that becomes the wallet's sole initial owner. Does not affect the address.
  /// @return addr  Address of the deployed BeaconProxy.
  function deployWallet(
    bytes32 walletId,
    address wallet
  ) external onlyRelayer returns (address addr) {
    _storeParameters(
      ISmartWalletFactory.Parameters({
        wallet: wallet,
        passkeyAlgo: ISmartWalletFactory.PasskeyAlgo.None,
        credentialId: 0,
        qx: 0,
        qy: 0,
        n: "",
        e: ""
      })
    );
    addr = _deployProxy(walletId);
  }

  /// @notice Deploys a new SmartWallet with a passkey owner (ES256 or RS256) and an
  ///         optional EOA owner. Restricted to the relayer.
  /// @param walletId    CREATE2 salt. The wallet address is stable as long as (factory, id) is the same.
  /// @param wallet  Optional EOA that becomes an initial owner alongside the passkey; pass
  ///                address(0) to create a passkey-only wallet. Does not affect the address.
  /// @param passkey Passkey to register alongside the wallet owner. Algo determines which key fields are used.
  /// @return addr   Address of the deployed BeaconProxy.
  function deployWalletWithPasskey(
    bytes32 walletId,
    address wallet,
    InitialPasskey calldata passkey
  ) external onlyRelayer returns (address addr) {
    _storeParameters(
      ISmartWalletFactory.Parameters({
        wallet: wallet,
        passkeyAlgo: passkey.algo,
        credentialId: passkey.credentialId,
        qx: passkey.qx,
        qy: passkey.qy,
        n: passkey.n,
        e: passkey.e
      })
    );
    addr = _deployProxy(walletId);
  }

  /// @dev Writes the abi-encoded parameters blob to transient storage: length in the base
  ///      slot, data words in the consecutive slots after it.
  function _storeParameters(
    ISmartWalletFactory.Parameters memory params
  ) private {
    bytes memory blob = abi.encode(params);
    bytes32 slot = PARAMETERS_TSLOT;
    assembly ("memory-safe") {
      let len := mload(blob)
      tstore(slot, len)
      let words := div(add(len, 31), 32)
      for {
        let i := 0
      } lt(i, words) {
        i := add(i, 1)
      } {
        tstore(
          add(add(slot, 1), i),
          mload(add(blob, add(0x20, mul(i, 0x20))))
        )
      }
    }
  }

  /// @dev Deploys the BeaconProxy with a fixed `initialize()` call and clears transient parameters.
  ///      The 4-byte `initialize()` selector is constant, preserving address determinism.
  function _deployProxy(
    bytes32 walletId
  ) private returns (address addr) {
    addr = address(
      new BeaconProxy{ salt: walletId }(
        beaconImplementation,
        abi.encodeWithSignature("initialize()")
      )
    );

    walletIdToWallet[walletId] = addr;
    walletToWalletId[addr] = walletId;
    _walletIds.push(walletId);

    // Zeroing the length is enough — reads are gated on it, and transient storage
    // resets at the end of the transaction anyway.
    bytes32 slot = PARAMETERS_TSLOT;
    assembly ("memory-safe") {
      tstore(slot, 0)
    }
    emit WalletDeployed(walletId, addr);
  }
}
