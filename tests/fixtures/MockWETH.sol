// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "fixtures/MockERC20.sol";

/// @dev WETH stand-in: `deposit` mints 1:1 against the ETH sent.
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
}
