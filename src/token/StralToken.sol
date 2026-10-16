// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { ERC20 } from "@openzeppelin/contracts-5/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts-5/token/ERC20/extensions/ERC20Permit.sol";

/// @title StralToken
/// @notice The Palantex platform token. ERC-20 with ERC-2612 permit. Full supply minted to treasury
///         at construction.
contract StralToken is ERC20, ERC20Permit {
  uint256 public constant TOTAL_SUPPLY = 250_000_000 ether;

  constructor(
    address treasury,
    string memory name_,
    string memory symbol_
  ) ERC20(name_, symbol_) ERC20Permit(name_) {
    _mint(treasury, TOTAL_SUPPLY);
  }

  function burn(uint256 amount) external {
    _burn(msg.sender, amount);
  }
}
