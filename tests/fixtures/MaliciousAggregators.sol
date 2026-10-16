// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { SwapExecutor } from "src/swap/SwapExecutor.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";

/// @dev Allowlisted aggregator that takes the approved input and pays nothing.
///      Must be caught by the executor's `minAmountOut` check.
contract TheftAggregator {
  function swap(IERC20 tokenIn, uint256 amount) external {
    tokenIn.transferFrom(msg.sender, address(this), amount);
  }
}

/// @dev Allowlisted aggregator that pays the output to itself instead of the executor.
///      The executor's balance-delta check must reject it.
contract SelfPayAggregator {
  function swap(
    IERC20 tokenIn,
    uint256 amount,
    MockERC20 tokenOut,
    uint256 payAmount
  ) external {
    tokenIn.transferFrom(msg.sender, address(this), amount);
    tokenOut.mint(address(this), payAmount);
  }
}

/// @dev Allowlisted aggregator that tries to reenter the calling wallet's `swap` during
///      execution. The wallet's auth gate must reject it (the aggregator is not an owner).
contract ReentrantWalletAggregator {
  function swap(
    SmartWallet wallet,
    address tokenIn,
    address tokenOut,
    uint256 amountIn
  ) external {
    wallet.swap(
      tokenIn,
      tokenOut,
      amountIn,
      0,
      address(this),
      "",
      type(uint256).max,
      MultiSignerAuth.Auth({
        authType: MultiSignerAuth.AuthType.Direct,
        payload: ""
      })
    );
  }
}

/// @dev Allowlisted aggregator that reenters `executeSwap` mid-swap with zero amounts,
///      attempting to drain the executor's in-flight input via the leftover-refund path.
///      The executor's reentrancy guard must block it.
contract NestedExecutorAggregator {
  function noop() external {}

  function swap(
    SwapExecutor executor,
    address tokenIn,
    address tokenOut
  ) external {
    executor.executeSwap(
      tokenIn,
      tokenOut,
      0,
      0,
      address(this),
      abi.encodeCall(NestedExecutorAggregator.noop, ())
    );
  }
}
