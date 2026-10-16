// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
// Libs
import { ECDSA } from "@openzeppelin/contracts-5/utils/cryptography/ECDSA.sol";
import { PasskeySignature } from "src/libs/PasskeySignature.sol";

/// @title MultiSignerAuth
/// @notice Abstract module providing multi-signer authentication for upgradeable contracts.
///         Supports three owner types — EOA wallets, ES256 (P-256) passkeys, and RS256 (RSA)
///         passkeys — all sharing equal rights. Authentication is unified through a single
///         `onlyUser` modifier backed by EIP-712 typed data signing.
/// @dev Inheritors must call `__MultiSignerAuth_init` in their initializer.
///
///      EOA wallets may authenticate either by signing a typed message (EOASig) or by calling
///      directly (Direct). Passkeys may only authenticate via typed messages, since they have
///      no Ethereum address to use as msg.sender.
///
///      The nonce is consumed only on successful signed auth, preventing a failed attempt
///      from blocking the next valid one. Direct calls bypass nonce entirely.
abstract contract MultiSignerAuth is
  Initializable,
  EIP712Upgradeable
{
  // ====== TYPES ====== //

  /// @notice Discriminator for the authentication method used in a call.
  enum AuthType {
    Direct,
    EOASig,
    ES256,
    RS256
  }

  /// @notice Authentication credentials passed to every protected function.
  /// @dev Payload encoding per AuthType:
  ///   Direct  — empty (msg.sender must be a registered wallet owner)
  ///   EOASig  — raw 65-byte ECDSA signature over the EIP-712 digest
  ///   ES256   — abi.encode(bytes32 credentialId, ES256Signature sig, bytes authenticatorData, bytes clientDataJSON)
  ///   RS256   — abi.encode(bytes32 credentialId, bytes sig, bytes authenticatorData, bytes clientDataJSON)
  ///
  ///   For passkey types, `credentialId` is keccak256 of the raw WebAuthn credential ID.
  ///   `authenticatorData` and `clientDataJSON` are the raw bytes from the WebAuthn assertion.
  ///   The WebAuthn challenge must be set to the EIP-712 typed data hash of the operation.
  struct Auth {
    AuthType authType;
    bytes payload;
  }

  /// @notice RSA public key for RS256 passkey owners.
  /// @dev `n` must be >= 256 bytes (2048-bit minimum). Both fields are big-endian.
  struct RS256PublicKey {
    bytes n;
    bytes e;
  }

  /// @notice Describes a single owner entry returned by `getOwners`.
  /// @dev `wallet` is populated for Direct (EOA) owners.
  ///      `credentialId`, `qx`, `qy` are populated for ES256 owners.
  ///      `credentialId`, `n`, `e` are populated for RS256 owners.
  ///      Unused fields are zero / empty.
  struct OwnerEntry {
    AuthType ownerType;
    address wallet;
    bytes32 credentialId;
    bytes32 qx;
    bytes32 qy;
    bytes n;
    bytes e;
  }

  // ====== ERRORS ====== //

  error Unauthorized();
  error UnknownCredential(bytes32 credentialId);
  error InvalidPasskey();
  error SignatureExpired(uint256 deadline);
  error CannotRemoveLastOwner();

  // ====== EVENTS ====== //

  event WalletOwnerAdded(address indexed owner);
  event WalletOwnerRemoved(address indexed owner);
  event ES256OwnerAdded(bytes32 indexed credentialId);
  event ES256OwnerRemoved(bytes32 indexed credentialId);
  event RS256OwnerAdded(bytes32 indexed credentialId);
  event RS256OwnerRemoved(bytes32 indexed credentialId);

  // ====== STORAGE ====== //

  /// @notice Sequential nonce consumed by every signed (non-Direct) authenticated call.
  /// @dev Callers must read the current nonce and include it in the typed data before signing.
  ///      Direct calls do not consume the nonce.
  uint256 public nonce;

  mapping(address => bool) private _walletOwners;
  address[] private _walletOwnerList;

  mapping(bytes32 => PasskeySignature.ES256PublicKey)
    private _es256Owners;
  bytes32[] private _es256CredentialList;

  mapping(bytes32 => RS256PublicKey) private _rs256Owners;
  bytes32[] private _rs256CredentialList;

  // ====== TYPE HASHES ====== //

  bytes32 private constant ADD_WALLET_OWNER_TYPEHASH =
    keccak256(
      "AddWalletOwner(address owner,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant REMOVE_WALLET_OWNER_TYPEHASH =
    keccak256(
      "RemoveWalletOwner(address owner,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant ADD_ES256_OWNER_TYPEHASH =
    keccak256(
      "AddES256Owner(bytes32 credentialId,bytes32 qx,bytes32 qy,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant REMOVE_ES256_OWNER_TYPEHASH =
    keccak256(
      "RemoveES256Owner(bytes32 credentialId,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant ADD_RS256_OWNER_TYPEHASH =
    keccak256(
      "AddRS256Owner(bytes32 credentialId,bytes32 nHash,bytes32 eHash,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant REMOVE_RS256_OWNER_TYPEHASH =
    keccak256(
      "RemoveRS256Owner(bytes32 credentialId,uint256 nonce,uint256 deadline)"
    );

  // ====== INITIALIZER ====== //

  /// @dev Called by the inheriting contract's initializer. Initializes the EIP-712 domain.
  /// @param name    EIP-712 domain name (e.g. "SmartWallet").
  /// @param version EIP-712 domain version (e.g. "1").
  function __MultiSignerAuth_init(
    string memory name,
    string memory version
  ) internal onlyInitializing {
    __EIP712_init(name, version);
  }

  // ====== MODIFIER ====== //

  /// @dev Central auth gate. Every protected function passes its own EIP-712 struct hash;
  ///      this modifier delegates verification to `_verifyAuth` which dispatches by auth type.
  ///      The struct hash must include the current `nonce` so signed messages cannot be
  ///      replayed, and the `deadline` so signed messages cannot be executed after expiry.
  modifier onlyUser(
    Auth calldata auth,
    bytes32 structHash,
    uint256 deadline
  ) {
    _verifyAuth(auth, structHash, deadline);
    _;
  }

  // ====== INTERNALS ====== //

  /// @dev Verifies `auth` against the EIP-712 typed hash of `structHash`.
  ///
  ///      Direct calls bypass signature verification entirely and rely on msg.sender being a
  ///      registered wallet owner — no nonce is consumed.
  ///
  ///      All signed auth types (EOASig, ES256, RS256) verify against
  ///      `_hashTypedDataV4(structHash)` and increment the nonce only on success, preventing
  ///      a failed attempt from blocking the next valid one. Signed messages carry a
  ///      `deadline` (included in the struct hash) after which they are rejected; Direct
  ///      calls ignore the deadline.
  ///
  ///      ES256 existence check uses `qx != 0` as a proxy for an unregistered credential.
  ///      A legitimate P-256 key with qx == 0 would be incorrectly rejected, but such a key
  ///      is computationally indistinguishable from unregistered (probability ~2^-256).
  function _verifyAuth(
    Auth calldata auth,
    bytes32 structHash,
    uint256 deadline
  ) internal {
    if (auth.authType == AuthType.Direct) {
      if (!_walletOwners[msg.sender]) revert Unauthorized();
      return;
    }

    if (block.timestamp > deadline) revert SignatureExpired(deadline);

    bytes32 digest = _hashTypedDataV4(structHash);

    if (auth.authType == AuthType.EOASig) {
      if (!_walletOwners[ECDSA.recover(digest, auth.payload)])
        revert Unauthorized();
    } else if (auth.authType == AuthType.ES256) {
      (
        bytes32 credentialId,
        PasskeySignature.ES256Signature memory sig,
        bytes memory authenticatorData,
        bytes memory clientDataJSON
      ) = abi.decode(
          auth.payload,
          (bytes32, PasskeySignature.ES256Signature, bytes, bytes)
        );

      PasskeySignature.ES256PublicKey memory pubKey = _es256Owners[
        credentialId
      ];
      if (pubKey.qx == 0) revert UnknownCredential(credentialId);
      if (
        !PasskeySignature.verifyES256(
          digest,
          authenticatorData,
          clientDataJSON,
          sig,
          pubKey,
          false
        )
      ) revert InvalidPasskey();
    } else {
      (
        bytes32 credentialId,
        bytes memory sig,
        bytes memory authenticatorData,
        bytes memory clientDataJSON
      ) = abi.decode(auth.payload, (bytes32, bytes, bytes, bytes));

      RS256PublicKey storage pubKey = _rs256Owners[credentialId];
      if (pubKey.n.length == 0)
        revert UnknownCredential(credentialId);
      if (
        !PasskeySignature.verifyRS256(
          digest,
          authenticatorData,
          clientDataJSON,
          sig,
          pubKey.n,
          pubKey.e,
          false
        )
      ) revert InvalidPasskey();
    }

    nonce++;
  }

  /// @dev Registers an EOA as an owner without auth — used during initialization only.
  function _registerWalletOwner(address owner) internal {
    if (!_walletOwners[owner]) _walletOwnerList.push(owner);

    _walletOwners[owner] = true;
    emit WalletOwnerAdded(owner);
  }

  /// @dev Registers an ES256 passkey as an owner without auth — used during initialization only.
  function _registerES256Owner(
    bytes32 credentialId,
    PasskeySignature.ES256PublicKey memory pubKey
  ) internal {
    if (_es256Owners[credentialId].qx == 0)
      _es256CredentialList.push(credentialId);

    _es256Owners[credentialId] = pubKey;
    emit ES256OwnerAdded(credentialId);
  }

  /// @dev Registers an RS256 passkey as an owner without auth — used during initialization only.
  function _registerRS256Owner(
    bytes32 credentialId,
    RS256PublicKey memory pubKey
  ) internal {
    if (_rs256Owners[credentialId].n.length == 0)
      _rs256CredentialList.push(credentialId);

    _rs256Owners[credentialId] = pubKey;
    emit RS256OwnerAdded(credentialId);
  }

  /// @dev Total number of registered owners across all owner types.
  function _ownerCount() private view returns (uint256) {
    return
      _walletOwnerList.length +
      _es256CredentialList.length +
      _rs256CredentialList.length;
  }

  /// @dev Hook invoked after an EOA owner is added via `addWalletOwner` (not during
  ///      initialization). Lets inheritors react to post-init owner additions.
  function _afterWalletOwnerAdded(address owner) internal virtual {}

  // ====== VIEW FUNCTIONS ====== //

  /// @notice Returns whether an address is a registered EOA wallet owner.
  function isWalletOwner(address addr) public view returns (bool) {
    return _walletOwners[addr];
  }

  /// @notice Returns all registered owners — EOA wallets, ES256, and RS256 — as a single array.
  /// @dev Check `ownerType` to determine which fields are populated on each entry.
  function getOwners()
    external
    view
    returns (OwnerEntry[] memory owners)
  {
    uint256 walletLen = _walletOwnerList.length;
    uint256 es256Len = _es256CredentialList.length;
    uint256 rs256Len = _rs256CredentialList.length;
    owners = new OwnerEntry[](walletLen + es256Len + rs256Len);

    uint256 idx = 0;
    for (uint256 i = 0; i < walletLen; i++) {
      owners[idx++] = OwnerEntry({
        ownerType: AuthType.Direct,
        wallet: _walletOwnerList[i],
        credentialId: 0,
        qx: 0,
        qy: 0,
        n: "",
        e: ""
      });
    }
    for (uint256 i = 0; i < es256Len; i++) {
      bytes32 cid = _es256CredentialList[i];
      PasskeySignature.ES256PublicKey storage pk = _es256Owners[cid];
      owners[idx++] = OwnerEntry({
        ownerType: AuthType.ES256,
        wallet: address(0),
        credentialId: cid,
        qx: pk.qx,
        qy: pk.qy,
        n: "",
        e: ""
      });
    }
    for (uint256 i = 0; i < rs256Len; i++) {
      bytes32 cid = _rs256CredentialList[i];
      RS256PublicKey storage pk = _rs256Owners[cid];
      owners[idx++] = OwnerEntry({
        ownerType: AuthType.RS256,
        wallet: address(0),
        credentialId: cid,
        qx: 0,
        qy: 0,
        n: pk.n,
        e: pk.e
      });
    }
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Adds an EOA address as an owner.
  /// @param owner    The address to grant ownership to.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Credentials of an existing owner authorizing this change.
  function addWalletOwner(
    address owner,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(ADD_WALLET_OWNER_TYPEHASH, owner, nonce, deadline)
      ),
      deadline
    )
  {
    if (!_walletOwners[owner]) _walletOwnerList.push(owner);

    _walletOwners[owner] = true;
    emit WalletOwnerAdded(owner);

    _afterWalletOwnerAdded(owner);
  }

  /// @notice Removes an EOA address from the owners.
  /// @dev Reverts if this would remove the wallet's last remaining owner.
  /// @param owner    The address to revoke ownership from.
  /// @param deadline Timestamp after which a signed authorization is no longer valid.
  /// @param auth     Credentials of an existing owner authorizing this change.
  function removeWalletOwner(
    address owner,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(
          REMOVE_WALLET_OWNER_TYPEHASH,
          owner,
          nonce,
          deadline
        )
      ),
      deadline
    )
  {
    if (_walletOwners[owner]) {
      if (_ownerCount() == 1) revert CannotRemoveLastOwner();
      uint256 len = _walletOwnerList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_walletOwnerList[i] == owner) {
          _walletOwnerList[i] = _walletOwnerList[len - 1];
          _walletOwnerList.pop();
          break;
        }
      }
    }

    _walletOwners[owner] = false;
    emit WalletOwnerRemoved(owner);
  }

  /// @notice Registers an ES256 (P-256) passkey as an owner.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID.
  /// @param pubKey       P-256 public key (qx, qy) of the passkey.
  /// @param deadline     Timestamp after which a signed authorization is no longer valid.
  /// @param auth         Credentials of an existing owner authorizing this change.
  function addES256Owner(
    bytes32 credentialId,
    PasskeySignature.ES256PublicKey calldata pubKey,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(
          ADD_ES256_OWNER_TYPEHASH,
          credentialId,
          pubKey.qx,
          pubKey.qy,
          nonce,
          deadline
        )
      ),
      deadline
    )
  {
    if (_es256Owners[credentialId].qx == 0)
      _es256CredentialList.push(credentialId);

    _es256Owners[credentialId] = pubKey;
    emit ES256OwnerAdded(credentialId);
  }

  /// @notice Removes an ES256 passkey owner.
  /// @dev Reverts if this would remove the wallet's last remaining owner.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID to remove.
  /// @param deadline     Timestamp after which a signed authorization is no longer valid.
  /// @param auth         Credentials of an existing owner authorizing this change.
  function removeES256Owner(
    bytes32 credentialId,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(
          REMOVE_ES256_OWNER_TYPEHASH,
          credentialId,
          nonce,
          deadline
        )
      ),
      deadline
    )
  {
    if (_es256Owners[credentialId].qx != 0) {
      if (_ownerCount() == 1) revert CannotRemoveLastOwner();
      uint256 len = _es256CredentialList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_es256CredentialList[i] == credentialId) {
          _es256CredentialList[i] = _es256CredentialList[len - 1];
          _es256CredentialList.pop();
          break;
        }
      }
    }

    delete _es256Owners[credentialId];
    emit ES256OwnerRemoved(credentialId);
  }

  /// @notice Registers an RS256 (RSA) passkey as an owner.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID.
  /// @param n            RSA modulus (big-endian, >= 2048-bit).
  /// @param e            RSA public exponent (big-endian).
  /// @param deadline     Timestamp after which a signed authorization is no longer valid.
  /// @param auth         Credentials of an existing owner authorizing this change.
  /// @dev `n` and `e` are hashed into the EIP-712 struct (RS256 keys are too large to encode raw).
  function addRS256Owner(
    bytes32 credentialId,
    bytes calldata n,
    bytes calldata e,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(
          ADD_RS256_OWNER_TYPEHASH,
          credentialId,
          keccak256(n),
          keccak256(e),
          nonce,
          deadline
        )
      ),
      deadline
    )
  {
    if (_rs256Owners[credentialId].n.length == 0)
      _rs256CredentialList.push(credentialId);

    _rs256Owners[credentialId] = RS256PublicKey({ n: n, e: e });
    emit RS256OwnerAdded(credentialId);
  }

  /// @notice Removes an RS256 passkey owner.
  /// @dev Reverts if this would remove the wallet's last remaining owner.
  /// @param credentialId keccak256 of the raw WebAuthn credential ID to remove.
  /// @param deadline     Timestamp after which a signed authorization is no longer valid.
  /// @param auth         Credentials of an existing owner authorizing this change.
  function removeRS256Owner(
    bytes32 credentialId,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      keccak256(
        abi.encode(
          REMOVE_RS256_OWNER_TYPEHASH,
          credentialId,
          nonce,
          deadline
        )
      ),
      deadline
    )
  {
    if (_rs256Owners[credentialId].n.length > 0) {
      if (_ownerCount() == 1) revert CannotRemoveLastOwner();
      uint256 len = _rs256CredentialList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_rs256CredentialList[i] == credentialId) {
          _rs256CredentialList[i] = _rs256CredentialList[len - 1];
          _rs256CredentialList.pop();
          break;
        }
      }
    }

    delete _rs256Owners[credentialId];
    emit RS256OwnerRemoved(credentialId);
  }
}
