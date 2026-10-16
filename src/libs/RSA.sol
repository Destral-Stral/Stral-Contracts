// SPDX-License-Identifier: MIT
// Adapted from OpenZeppelin Contracts v5.1.0 (utils/cryptography/RSA.sol)
pragma solidity ^0.8.24;

library RSA {
    /// @dev Verifies a PKCS#1 v1.5 RSA signature. Hashes `data` with SHA-256 first.
    function pkcs1Sha256(
        bytes memory data,
        bytes memory s,
        bytes memory e,
        bytes memory n
    ) internal view returns (bool) {
        return pkcs1Sha256(sha256(data), s, e, n);
    }

    /// @dev Verifies a PKCS#1 v1.5 RSA signature against a pre-computed SHA-256 digest.
    function pkcs1Sha256(
        bytes32 digest,
        bytes memory s,
        bytes memory e,
        bytes memory n
    ) internal view returns (bool) {
        unchecked {
            uint256 length = n.length;
            if (length < 0x100 || length != s.length) return false;

            // Verify s < n
            for (uint256 i = 0; i < length; i += 0x20) {
                uint256 p = _min(i, length - 0x20);
                bytes32 sp = _unsafeReadBytes32(s, p);
                bytes32 np = _unsafeReadBytes32(n, p);
                if (sp < np) {
                    break;
                } else if (sp > np || p == length - 0x20) {
                    return false;
                }
            }

            // RSAVP1: compute s^e mod n via modexp precompile (0x05)
            bytes memory buffer = _modExpBytes(s, e, n);

            // Validate PKCS#1 v1.5 EM: 0x00 | 0x01 | PS (0xFF*) | 0x00 | DigestInfo | digest
            bytes32 params;
            bytes32 mask;
            uint256 offset;

            if (bytes1(_unsafeReadBytes32(buffer, length - 0x32)) == 0x31) {
                offset = 0x34;
                params = 0x003031300d060960864801650304020105000420000000000000000000000000;
                mask = 0xffffffffffffffffffffffffffffffffffffffff000000000000000000000000;
            } else if (bytes1(_unsafeReadBytes32(buffer, length - 0x30)) == 0x2F) {
                offset = 0x32;
                params = 0x00302f300b060960864801650304020104200000000000000000000000000000;
                mask = 0xffffffffffffffffffffffffffffffffffff0000000000000000000000000000;
            } else {
                return false;
            }

            uint256 paddingEnd = length - offset;
            for (uint256 i = 2; i < paddingEnd; ++i) {
                if (bytes1(_unsafeReadBytes32(buffer, i)) != 0xFF) return false;
            }

            return
                bytes2(0x0001) == bytes2(_unsafeReadBytes32(buffer, 0x00)) &&
                params == _unsafeReadBytes32(buffer, paddingEnd) & mask &&
                digest == _unsafeReadBytes32(buffer, length - 0x20);
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _modExpBytes(
        bytes memory b,
        bytes memory e,
        bytes memory m
    ) private view returns (bytes memory result) {
        uint256 mLen = m.length;
        result = abi.encodePacked(b.length, e.length, mLen, b, e, m);
        assembly ("memory-safe") {
            let dataPtr := add(result, 0x20)
            pop(staticcall(gas(), 0x05, dataPtr, mload(result), dataPtr, mLen))
            mstore(result, mLen)
            mstore(0x40, add(dataPtr, mLen))
        }
    }

    function _unsafeReadBytes32(bytes memory array, uint256 offset) private pure returns (bytes32 result) {
        assembly ("memory-safe") {
            result := mload(add(add(array, 0x20), offset))
        }
    }
}
