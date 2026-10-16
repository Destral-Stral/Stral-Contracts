// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";
import {SmartWallet} from "src/smartWallet/SmartWallet.sol";
import {MultiSignerAuth} from "src/module/MultiSignerAuth.sol";

contract ReentrantStaking {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    bool public attempted;
    bool public reentered;
    mapping(address => uint256) public staked;

    constructor(IERC20 token_) {
        token = token_;
    }

    function stake(uint256 amount) external {
        attempted = true;

        MultiSignerAuth.Auth memory auth =
            MultiSignerAuth.Auth({authType: MultiSignerAuth.AuthType.Direct, payload: ""});

        try SmartWallet(payable(msg.sender)).transferAssets(address(token), 1, type(uint256).max, auth) {
            reentered = true;
        } catch {}

        staked[msg.sender] += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external {
        staked[msg.sender] -= amount;
        token.safeTransfer(msg.sender, amount);
    }
}
