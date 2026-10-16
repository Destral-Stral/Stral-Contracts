// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { Proxy } from "@openzeppelin/contracts-5/proxy/Proxy.sol";
// Interfaces
import { IBeacon } from "@openzeppelin/contracts-5/proxy/beacon/IBeacon.sol";
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";

/// @title SmartWalletRecovery
/// @notice Temporary SmartWallet implementation that lets the coordinator owner register a
///         new owner (EOA, ES256 passkey or RS256 passkey) on a wallet whose owner lost
///         every credential. See `scripts/rescue/LOST-PASSKEY-RECOVERY.md`.
/// @dev All wallets share one beacon, so while the beacon points here this code is live for
///      every wallet:
///
///        - The only functions added to the wallets are the three `recover*Owner`. They
///          can only be called by the coordinator owner, who can already put any code
///          behind the beacon, so they give it no authority it does not have.
///        - Every other call is forwarded untouched to {originalImplementation}, the
///          implementation the beacon served when this contract was deployed, so all
///          wallets keep running the exact same code they ran before.
///        - Called directly (not through a wallet proxy) it does nothing: the recover
///          functions revert and the forwarder is disabled, so its own storage can never
///          be initialized.
///
///      Reusable for any wallet, but only for as long as the beacon serves
///      {originalImplementation}: that is the implementation the storage layout below was
///      checked against, and {checkBeaconUnchanged} makes the batch revert once the
///      wallets have been upgraded. A new implementation needs a new deployment, after the
///      storage re-check described in the STORAGE section.
///
///      Intended use is one atomic multisig batch: {checkBeaconUnchanged}, then
///      `factory.upgradeTo(this)`, `wallet.recover*Owner(...)`,
///      `factory.upgradeTo(originalImplementation)`.
contract SmartWalletRecovery is Proxy {
  // ====== TYPES ====== //

  /// @dev Same layout as `PasskeySignature.ES256PublicKey`.
  struct ES256PublicKey {
    bytes32 qx;
    bytes32 qy;
  }

  /// @dev Same layout as `MultiSignerAuth.RS256PublicKey`.
  struct RS256PublicKey {
    bytes n;
    bytes e;
  }

  // ====== ERRORS ====== //

  error ZeroAddress();
  error NotProxied();
  error NotCoordinatorOwner();
  error InvalidOwner();
  error BeaconImplementationChanged(address current);

  // ====== EVENTS ====== //

  /// @dev Same signatures as the events of MultiSignerAuth, so a recovered owner is indexed
  ///      like any owner added through the wallet itself.
  event WalletOwnerAdded(address indexed owner);
  event ES256OwnerAdded(bytes32 indexed credentialId);
  event RS256OwnerAdded(bytes32 indexed credentialId);

  // ====== STORAGE ====== //

  // These variables are never stored in this contract: the recover functions run through
  // a wallet proxy, so they address the WALLET's storage. They must sit on the exact slots
  // the live SmartWallet implementation uses for its owner registries, or a recovery
  // writes somewhere else and corrupts the wallet.
  //
  // RE-CHECK BEFORE DEPLOYING THIS CONTRACT FOR A NEW IMPLEMENTATION (a deployed instance
  // only works while the beacon serves the implementation it was deployed against). The
  // layout below is only valid if, in the implementation the beacon currently serves:
  //   - slot 54: `_walletOwners`        mapping(address => bool)
  //   - slot 55: `_walletOwnerList`     address[]
  //   - slot 56: `_es256Owners`         mapping(bytes32 => struct { bytes32 qx; bytes32 qy; })
  //   - slot 57: `_es256CredentialList` bytes32[]
  //   - slot 58: `_rs256Owners`         mapping(bytes32 => struct { bytes n; bytes e; })
  //   - slot 59: `_rs256CredentialList` bytes32[]
  //   all at offset 0, struct members in that order;
  //   - an owner is registered exactly as in MultiSignerAuth._registerWalletOwner,
  //     _registerES256Owner and _registerRS256Owner: push the key to the list if the entry
  //     is unset (flag false, `qx == 0`, `n.length == 0`), then write the entry.
  // How to check:
  //   1. live layout: `storageLayout.storage` and `storageLayout.types` in
  //      deployers/deployments/<env>/<network>/SmartWallet_Implementation.json, after
  //      confirming its `address` is what `beacon.implementation()` returns on chain;
  //   2. this contract: `forge inspect SmartWalletRecovery storage-layout`;
  //   3. `forge test --match-test test_layout_matchesDeploymentRecords` (records vs the
  //      slots) and `--match-test "test_recover.*_writesOnly"` (exact writes);
  //   4. the fork scenarios, which read each new owner back through the live code.
  // If a slot moved, change the declarations below and the slot constants in
  // tests/unit/WalletRecoveryTest.t.sol together. Never add, remove or reorder variables
  // here for any other reason.

  /// @dev Slots 0-53 (Initializable, EIP712Upgradeable, nonce) are never read or written.
  uint256[54] private __gapBeforeOwners;
  /// @dev Slot 54, `MultiSignerAuth._walletOwners`.
  mapping(address => bool) private _walletOwners;
  /// @dev Slot 55, `MultiSignerAuth._walletOwnerList`.
  address[] private _walletOwnerList;
  /// @dev Slot 56, `MultiSignerAuth._es256Owners`.
  mapping(bytes32 => ES256PublicKey) private _es256Owners;
  /// @dev Slot 57, `MultiSignerAuth._es256CredentialList`.
  bytes32[] private _es256CredentialList;
  /// @dev Slot 58, `MultiSignerAuth._rs256Owners`.
  mapping(bytes32 => RS256PublicKey) private _rs256Owners;
  /// @dev Slot 59, `MultiSignerAuth._rs256CredentialList`.
  bytes32[] private _rs256CredentialList;

  // ====== IMMUTABLES ====== //

  /// @dev This contract's own address, to tell a direct call from a proxied one.
  address private immutable _self;

  /// @notice The UpgradeableBeacon shared by all SmartWallet proxies.
  IBeacon public immutable beacon;
  /// @notice Implementation the beacon served when this contract was deployed, and the one
  ///         its storage layout was checked against. Every call other than the recover
  ///         functions is forwarded to it, and the beacon must be set back to it.
  address public immutable originalImplementation;
  /// @notice Coordinator whose owner is the only account allowed to recover a wallet.
  ISmartWalletCoordinator public immutable walletCoordinator;

  // ====== CONSTRUCTOR ====== //

  /// @param beacon_      The UpgradeableBeacon of the SmartWalletFactory.
  /// @param coordinator_ The SmartWalletCoordinator of the wallets.
  constructor(IBeacon beacon_, ISmartWalletCoordinator coordinator_) {
    if (address(coordinator_) == address(0)) revert ZeroAddress();

    _self = address(this);
    beacon = beacon_;
    originalImplementation = beacon_.implementation();
    walletCoordinator = coordinator_;
  }

  // ====== RECEIVE ====== //

  /// @dev Plain ETH transfers are forwarded like any other call, so they succeed or revert
  ///      exactly as they do on {originalImplementation}.
  receive() external payable {
    _fallback();
  }

  // ====== MODIFIER ====== //

  /// @dev Restricts a recovery to the coordinator owner, called through a wallet proxy.
  modifier onlyCoordinatorOwner() {
    if (address(this) == _self) revert NotProxied();
    if (msg.sender != walletCoordinator.owner())
      revert NotCoordinatorOwner();
    _;
  }

  // ====== INTERNALS ====== //

  /// @dev Target of the forwarder inherited from {Proxy}. Reverts on a direct call so the
  ///      original implementation never runs against this contract's own storage.
  function _implementation()
    internal
    view
    override
    returns (address)
  {
    if (address(this) == _self) revert NotProxied();
    return originalImplementation;
  }

  // ====== VIEW FUNCTIONS ====== //

  /// @notice Reverts if the beacon no longer serves {originalImplementation}.
  /// @dev First call of the recovery batch, sent to this contract directly: if the wallets
  ///      were upgraded after this contract was deployed, its storage layout is no longer
  ///      proven and restoring {originalImplementation} at the end of the batch would
  ///      downgrade them, so the whole batch must revert instead.
  function checkBeaconUnchanged() external view {
    address current = beacon.implementation();
    if (current != originalImplementation)
      revert BeaconImplementationChanged(current);
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Registers `owner` as an EOA owner of the wallet this is called through.
  /// @dev Same effects as `MultiSignerAuth._registerWalletOwner`. Existing owners, the
  ///      nonce and the whitelist are left untouched.
  function recoverWalletOwner(
    address owner
  ) external onlyCoordinatorOwner {
    if (owner == address(0)) revert InvalidOwner();

    if (!_walletOwners[owner]) _walletOwnerList.push(owner);

    _walletOwners[owner] = true;
    emit WalletOwnerAdded(owner);
  }

  /// @notice Registers an ES256 (P-256) passkey as an owner of the wallet this is called
  ///         through.
  /// @dev Same effects as `MultiSignerAuth._registerES256Owner`. A zero `qx` is refused:
  ///      the wallet treats it as an unregistered credential.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID.
  /// @param qx           P-256 public key x-coordinate.
  /// @param qy           P-256 public key y-coordinate.
  function recoverES256Owner(
    bytes32 credentialId,
    bytes32 qx,
    bytes32 qy
  ) external onlyCoordinatorOwner {
    if (qx == 0) revert InvalidOwner();

    if (_es256Owners[credentialId].qx == 0)
      _es256CredentialList.push(credentialId);

    _es256Owners[credentialId] = ES256PublicKey({ qx: qx, qy: qy });
    emit ES256OwnerAdded(credentialId);
  }

  /// @notice Registers an RS256 (RSA) passkey as an owner of the wallet this is called
  ///         through.
  /// @dev Same effects as `MultiSignerAuth._registerRS256Owner`. An empty `n` is refused:
  ///      the wallet treats it as an unregistered credential.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID.
  /// @param n            RSA modulus (big-endian, >= 2048-bit).
  /// @param e            RSA public exponent (big-endian).
  function recoverRS256Owner(
    bytes32 credentialId,
    bytes calldata n,
    bytes calldata e
  ) external onlyCoordinatorOwner {
    if (n.length == 0) revert InvalidOwner();

    if (_rs256Owners[credentialId].n.length == 0)
      _rs256CredentialList.push(credentialId);

    _rs256Owners[credentialId] = RS256PublicKey({ n: n, e: e });
    emit RS256OwnerAdded(credentialId);
  }
}
