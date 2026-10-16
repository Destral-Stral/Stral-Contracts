// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { MockERC20 } from "fixtures/MockERC20.sol";

/// @dev Fake aggregator router for SwapModule tests. `swap` pulls `spendAmount` of
///      `tokenIn` from the caller (the SwapExecutor) and mints `payAmount` of `tokenOut`
///      to it — spendAmount < approved amount simulates partial fills, low payAmount
///      simulates excessive slippage.
contract MockAggregator {
  function swap(
    MockERC20 tokenIn,
    uint256 spendAmount,
    MockERC20 tokenOut,
    uint256 payAmount
  ) external {
    tokenIn.transferFrom(msg.sender, address(this), spendAmount);
    tokenOut.mint(msg.sender, payAmount);
  }

  function alwaysReverts() external pure {
    revert("AGGREGATOR_FAILED");
  }
}
