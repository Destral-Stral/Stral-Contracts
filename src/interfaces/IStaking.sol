// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IStaking
/// @notice Minimal interface for the platform staking contract, consumed by SmartWallet.
///         Staking creates time-locked positions; each call to `stake` opens a new position
///         with a fixed lock duration set by the implementation.
interface IStaking {
  /// @notice Stakes `amount` of the platform token, opening a new time-locked position.
  /// @dev The lock duration is fixed by the staking contract. The caller must approve
  ///      `amount` to this contract before calling.
  /// @param amount Token amount to stake.
  function stake(uint256 amount) external;

  /// @notice Unstakes `amount`, clearing vested positions first then drawing from
  ///         unlocked direct positions for any shortfall.
  /// @param amount Token amount to unstake.
  function unstake(uint256 amount) external;
}
