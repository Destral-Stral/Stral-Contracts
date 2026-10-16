// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Libs
import { P256 } from "@openzeppelin/contracts-5/utils/cryptography/P256.sol";
import { RSA } from "src/libs/RSA.sol";

/// @title PasskeySignature
/// @notice Verifies WebAuthn assertions (ES256 and RS256) against an EIP-712 typed message hash.
///
/// Both algorithms follow the same WebAuthn verification flow:
///   1. authenticatorData must have the User Present flag set (User Verified optionally enforced).
///   2. clientDataJSON must contain `"type":"webauthn.get"`.
///   3. clientDataJSON must contain `"challenge":"<base64url(messageHash)>"`.
///   4. The signing input is SHA-256(authenticatorData || SHA-256(clientDataJSON)).
///
/// The `messageHash` (bytes32) is the challenge given to the authenticator — typically an
/// EIP-712 typed data hash or a keccak256 of the operation to authorize.
library PasskeySignature {
  // ── Types ─────────────────────────────────────────────────────────────────

  struct ES256PublicKey {
    bytes32 qx;
    bytes32 qy;
  }

  struct ES256Signature {
    bytes32 r;
    bytes32 s;
  }

  // ── Constants ─────────────────────────────────────────────────────────────

  // Minimum authenticatorData length per WebAuthn spec (rpIdHash[32] + flags[1] + signCount[4])
  uint256 private constant AUTH_DATA_MIN_LEN = 37;
  uint8 private constant FLAG_UP = 0x01; // User Present
  uint8 private constant FLAG_UV = 0x04; // User Verified

  // ── ES256 (P-256 / secp256r1) ─────────────────────────────────────────────

  /// @notice Verifies a WebAuthn ES256 assertion.
  /// @param messageHash      Typed message hash used as the WebAuthn challenge.
  /// @param authenticatorData  Raw authenticatorData from the WebAuthn response.
  /// @param clientDataJSON     Raw clientDataJSON (UTF-8) from the WebAuthn response.
  /// @param sig              P-256 signature (r, s).
  /// @param pubKey           Signer's P-256 public key (qx, qy).
  /// @param requireUV        Enforce the User Verified flag.
  function verifyES256(
    bytes32 messageHash,
    bytes memory authenticatorData,
    bytes memory clientDataJSON,
    ES256Signature memory sig,
    ES256PublicKey memory pubKey,
    bool requireUV
  ) internal view returns (bool) {
    if (!_checkAuthData(authenticatorData, requireUV)) return false;
    if (!_checkClientData(clientDataJSON, messageHash)) return false;

    bytes32 digest = sha256(
      abi.encodePacked(authenticatorData, sha256(clientDataJSON))
    );
    return P256.verify(digest, sig.r, sig.s, pubKey.qx, pubKey.qy);
  }

  // ── RS256 (RSA-PKCS#1 v1.5) ───────────────────────────────────────────────

  /// @notice Verifies a WebAuthn RS256 assertion.
  /// @param messageHash      Typed message hash used as the WebAuthn challenge.
  /// @param authenticatorData  Raw authenticatorData from the WebAuthn response.
  /// @param clientDataJSON     Raw clientDataJSON (UTF-8) from the WebAuthn response.
  /// @param signature        PKCS#1 v1.5 RSA signature.
  /// @param n                RSA modulus (big-endian, must be >= 256 bytes / 2048-bit).
  /// @param e                RSA public exponent (big-endian).
  /// @param requireUV        Enforce the User Verified flag.
  function verifyRS256(
    bytes32 messageHash,
    bytes memory authenticatorData,
    bytes memory clientDataJSON,
    bytes memory signature,
    bytes memory n,
    bytes memory e,
    bool requireUV
  ) internal view returns (bool) {
    if (!_checkAuthData(authenticatorData, requireUV)) return false;
    if (!_checkClientData(clientDataJSON, messageHash)) return false;

    bytes memory verificationData = abi.encodePacked(
      authenticatorData,
      sha256(clientDataJSON)
    );
    return RSA.pkcs1Sha256(verificationData, signature, e, n);
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  function _checkAuthData(
    bytes memory authenticatorData,
    bool requireUV
  ) private pure returns (bool) {
    if (authenticatorData.length < AUTH_DATA_MIN_LEN) return false;
    uint8 flags = uint8(authenticatorData[32]);
    if (flags & FLAG_UP == 0) return false;
    if (requireUV && flags & FLAG_UV == 0) return false;
    return true;
  }

  /// @dev The type member is checked positionally: per the WebAuthn spec's JSON
  ///      serialization, clientDataJSON always starts with `{"type":"`. Requiring the
  ///      `webauthn.get` type at index 0 prevents a crafted payload from smuggling the
  ///      needle inside another field's string value (e.g. in a `webauthn.create`
  ///      registration response).
  function _checkClientData(
    bytes memory clientDataJSON,
    bytes32 expectedChallenge
  ) private pure returns (bool) {
    bytes memory typePrefix = bytes('{"type":"webauthn.get"');
    if (!_startsWith(clientDataJSON, typePrefix)) return false;
    bytes memory challengeNeedle = abi.encodePacked(
      bytes('"challenge":"'),
      _base64urlEncode32(expectedChallenge),
      bytes('"')
    );
    return _containsBytes(clientDataJSON, challengeNeedle);
  }

  /// @dev Returns whether `haystack` begins with `prefix`.
  function _startsWith(
    bytes memory haystack,
    bytes memory prefix
  ) private pure returns (bool) {
    uint256 pLen = prefix.length;
    if (haystack.length < pLen) return false;
    bytes32 sliceHash;
    assembly {
      sliceHash := keccak256(add(haystack, 0x20), pLen)
    }
    return sliceHash == keccak256(prefix);
  }

  /// @dev Base64url-encodes a bytes32 value to exactly 43 characters (no padding).
  function _base64urlEncode32(
    bytes32 data
  ) private pure returns (bytes memory) {
    bytes
      memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    bytes memory result = new bytes(43);
    uint256 d = uint256(data);
    // 10 full groups of 3 bytes → 40 base64url chars
    for (uint256 i = 0; i < 10; i++) {
      uint256 group = (d >> (232 - i * 24)) & 0xFFFFFF;
      result[i * 4] = table[(group >> 18) & 0x3F];
      result[i * 4 + 1] = table[(group >> 12) & 0x3F];
      result[i * 4 + 2] = table[(group >> 6) & 0x3F];
      result[i * 4 + 3] = table[group & 0x3F];
    }
    // Remaining 2 bytes (16 bits) → 3 base64url chars
    uint256 tail = d & 0xFFFF;
    result[40] = table[(tail >> 10) & 0x3F];
    result[41] = table[(tail >> 4) & 0x3F];
    result[42] = table[(tail << 2) & 0x3F];
    return result;
  }

  /// @dev O(n*m) substring search using assembly to hash memory slices.
  function _containsBytes(
    bytes memory haystack,
    bytes memory needle
  ) private pure returns (bool) {
    uint256 hLen = haystack.length;
    uint256 nLen = needle.length;
    if (nLen == 0) return true;
    if (nLen > hLen) return false;
    bytes32 needleHash = keccak256(needle);
    uint256 limit = hLen - nLen;
    for (uint256 i = 0; i <= limit; i++) {
      bytes32 sliceHash;
      assembly {
        sliceHash := keccak256(add(add(haystack, 0x20), i), nLen)
      }
      if (sliceHash == needleHash) return true;
    }
    return false;
  }
}
