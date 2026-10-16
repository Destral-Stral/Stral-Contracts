// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts-5/token/ERC20/ERC20.sol";

contract RevertingERC20 is ERC20 {
    error TransferFailed();

    constructor() ERC20("Reverting Token", "RVT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert TransferFailed();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransferFailed();
    }
}

contract FalseReturnERC20 is ERC20 {
    constructor() ERC20("False Return Token", "FRT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100;
    address public immutable feeSink;

    constructor(address feeSink_) ERC20("Fee Token", "FEE") {
        feeSink = feeSink_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != feeSink && value > 0) {
            uint256 fee = value / FEE_BPS;
            super._update(from, feeSink, fee);
            super._update(from, to, value - fee);
            return;
        }

        super._update(from, to, value);
    }
}
