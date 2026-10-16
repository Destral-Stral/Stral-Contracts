// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface used by SmartWallet's SwapModule to execute swaps through the
///         shared SwapExecutor without importing the full contract.
interface ISwapExecutor {
  /// @notice Pulls `amountIn` of `tokenIn` from the caller, executes `data` against an
  ///         allowlisted aggregator `target`, and returns all proceeds to the caller.
  /// @param tokenIn      ERC-20 token being sold.
  /// @param tokenOut     ERC-20 token being bought.
  /// @param amountIn     Amount of `tokenIn` to pull from the caller.
  /// @param minAmountOut Minimum acceptable amount of `tokenOut`, reverts below this.
  /// @param target       Aggregator router to call. Must be on the executor's allowlist.
  /// @param data         Raw aggregator calldata (quoted off-chain).
  /// @return amountOut   Amount of `tokenOut` transferred back to the caller.
  function executeSwap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address target,
    bytes calldata data
  ) external returns (uint256 amountOut);
}
