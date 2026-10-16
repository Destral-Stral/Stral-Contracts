// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";

/// @notice Interface used by SmartWalletFactory and SmartWallet to query system-level
///         configuration from the coordinator without importing the full contract.
interface ISmartWalletCoordinator {
  /// @return The address of the coordinator's owner (the deployer / admin).
  function owner() external view returns (address);

  /// @notice Destination for all `transferAssets` calls across every SmartWallet.
  /// @return The strategy contract address funds are routed to on transfer.
  function strategyAddress() external view returns (address);

  /// @notice Minimum time that must pass after a recipient is added to a wallet's whitelist
  ///         before that recipient can receive withdrawals.
  /// @return Delay in seconds. Default is 86400 (24 hours).
  function withdrawalDelay() external view returns (uint256);

  /// @notice Returns whether a wallet has been blocked from routing funds to the strategy.
  /// @param wallet Address of the SmartWallet proxy to check.
  function isBlocked(address wallet) external view returns (bool);

  /// @notice Returns whether a token is on the coordinator's allowlist for asset movements.
  /// @param token ERC-20 token address to check.
  function isTokenAllowed(address token) external view returns (bool);

  /// @notice The platform token address used for staking operations.
  function stakingToken() external view returns (IERC20);

  /// @notice Contract address for platform staking via SmartWallet.stake.
  function stakingContract() external view returns (address);

  /// @notice Contract address for platform vesting operations.
  function vestingContract() external view returns (address);

  /// @notice The only address permitted to deploy wallets through the SmartWalletFactory.
  function relayer() external view returns (address);

  /// @notice Shared SwapExecutor contract used by SmartWallet swaps.
  function swapExecutor() external view returns (address);

  /// @notice The chain's WETH contract, used by SmartWallet to wrap native ETH.
  function weth() external view returns (address);
}
