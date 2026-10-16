// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Callback interface used by SmartWallet to read its deployment parameters from the
///         factory during construction. Avoids encoding parameters into the init code so that
///         the CREATE2 address depends only on (factory, id).
interface ISmartWalletFactory {
    /// @notice Supported passkey signature algorithms.
    enum PasskeyAlgo { None, ES256, RS256 }

    /// @notice Transient parameters set by the factory before each BeaconProxy deployment.
    ///         SmartWallet reads this during its `initialize` call.
    /// @dev Only meaningful during a SmartWallet constructor delegatecall. Returns zero values otherwise.
    ///      `qx`/`qy` are used for ES256; `n`/`e` are used for RS256. Unused fields are zero/empty.
    struct Parameters {
        address wallet;         // Initial EOA owner. Always set.
        PasskeyAlgo passkeyAlgo;
        bytes32 credentialId;   // keccak256 of the WebAuthn credential ID.
        bytes32 qx;             // ES256 public key x-coordinate.
        bytes32 qy;             // ES256 public key y-coordinate.
        bytes n;                // RS256 modulus (big-endian, >= 2048-bit).
        bytes e;                // RS256 public exponent (big-endian).
    }

    /// @return The address of the SmartWalletCoordinator.
    function coordinator() external view returns (address);

    /// @return The current transient deployment parameters.
    function parameters() external view returns (Parameters memory);
}
