// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal WETH interface used by SmartWallet to wrap native ETH.
interface IWETH {
  /// @notice Wraps `msg.value` of ETH into WETH credited to the caller.
  function deposit() external payable;
}
