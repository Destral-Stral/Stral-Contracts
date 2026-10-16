// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";

contract MockStaking {
  using SafeERC20 for IERC20;

  IERC20 public immutable token;
  mapping(address => uint256) public staked;

  constructor(IERC20 token_) {
    token = token_;
  }

  function stake(uint256 amount) external {
    staked[msg.sender] += amount;
    token.safeTransferFrom(msg.sender, address(this), amount);
  }

  function unstake(uint256 amount) external {
    staked[msg.sender] -= amount;
    token.safeTransfer(msg.sender, amount);
  }
}
