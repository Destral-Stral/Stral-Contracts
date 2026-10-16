// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { ReentrancyGuard } from "@openzeppelin/contracts-5/utils/ReentrancyGuard.sol";
// Libs
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";
// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";

/// @title SwapExecutor
/// @notice Shared periphery that executes aggregator swaps on behalf of SmartWallets.
///         The arbitrary aggregator call happens here — never from the wallet itself —
///         so a malicious or buggy route can only touch funds committed to this swap.
/// @dev Holds no funds between transactions: input is pulled from the caller, output and
///      any unspent input are returned to the caller in the same call. `executeSwap` is
///      permissionless by design — the contract only ever moves the caller's own funds.
///
///      Aggregator routers must be allowlisted by the coordinator's owner. Off-chain
///      quotes should use this contract's address as the swap initiator/recipient, since
///      it is the `msg.sender` the aggregator sees.
contract SwapExecutor is ReentrancyGuard {
  using SafeERC20 for IERC20;

  // ====== ERRORS ====== //

  error NotOwner();
  error SameToken();
  error AggregatorNotAllowed(address target);
  error SwapFailed();
  error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

  // ====== EVENTS ====== //

  event AggregatorAllowed(address indexed target);
  event AggregatorDisallowed(address indexed target);
  event SwapExecuted(
    address indexed caller,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut
  );

  // ====== STORAGE ====== //

  /// @notice Address of the SmartWalletCoordinator — admin checks resolve to its owner.
  ISmartWalletCoordinator public immutable coordinator;

  /// @notice Aggregator routers permitted as swap targets.
  mapping(address => bool) public allowedAggregators;
  address[] private _allowedAggregatorList;

  // ====== CONSTRUCTOR ====== //

  constructor(address _coordinator) {
    coordinator = ISmartWalletCoordinator(_coordinator);
  }

  // ====== MODIFIER ====== //

  /// @dev Admin authority is centralized on the coordinator's owner, mirroring the factory.
  modifier onlyOwner() {
    if (msg.sender != coordinator.owner()) revert NotOwner();
    _;
  }

  // ====== VIEW FUNCTIONS ====== //

  /// @notice Returns all aggregator routers currently on the allowlist.
  function getAllowedAggregators()
    external
    view
    returns (address[] memory)
  {
    return _allowedAggregatorList;
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Adds an aggregator router to the allowlist.
  /// @param target Router contract address to permit as a swap target.
  function allowAggregator(address target) external onlyOwner {
    if (!allowedAggregators[target])
      _allowedAggregatorList.push(target);

    allowedAggregators[target] = true;
    emit AggregatorAllowed(target);
  }

  /// @notice Removes an aggregator router from the allowlist.
  /// @param target Router contract address to revoke.
  function disallowAggregator(address target) external onlyOwner {
    if (allowedAggregators[target]) {
      uint256 len = _allowedAggregatorList.length;
      for (uint256 i = 0; i < len; i++) {
        if (_allowedAggregatorList[i] == target) {
          _allowedAggregatorList[i] = _allowedAggregatorList[
            len - 1
          ];
          _allowedAggregatorList.pop();
          break;
        }
      }
    }

    allowedAggregators[target] = false;
    emit AggregatorDisallowed(target);
  }

  /// @notice Executes a swap: pulls `amountIn` of `tokenIn` from the caller, runs the
  ///         aggregator calldata, enforces `minAmountOut` on the received `tokenOut`
  ///         balance delta, then returns proceeds and any unspent input to the caller.
  /// @dev The aggregator is approved for exactly `amountIn` and the approval is cleared
  ///      after the call. Output is measured as this contract's `tokenOut` balance delta,
  ///      so the quote's recipient must be this contract (the default for a caller-based
  ///      recipient) — never the wallet directly.
  ///
  ///      `nonReentrant` blocks an allowlisted aggregator from reentering mid-swap and
  ///      draining in-flight input through the leftover-refund path.
  function executeSwap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address target,
    bytes calldata data
  ) external nonReentrant returns (uint256 amountOut) {
    if (tokenIn == tokenOut) revert SameToken();
    if (!allowedAggregators[target])
      revert AggregatorNotAllowed(target);

    IERC20(tokenIn).safeTransferFrom(
      msg.sender,
      address(this),
      amountIn
    );

    uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

    IERC20(tokenIn).forceApprove(target, amountIn);
    (bool success, bytes memory returndata) = target.call(data);
    if (!success) {
      if (returndata.length == 0) revert SwapFailed();
      assembly {
        revert(add(returndata, 0x20), mload(returndata))
      }
    }
    IERC20(tokenIn).forceApprove(target, 0);

    amountOut =
      IERC20(tokenOut).balanceOf(address(this)) -
      outBefore;
    if (amountOut < minAmountOut)
      revert InsufficientOutput(amountOut, minAmountOut);

    IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

    uint256 leftover = IERC20(tokenIn).balanceOf(address(this));
    if (leftover > 0)
      IERC20(tokenIn).safeTransfer(msg.sender, leftover);

    emit SwapExecuted(
      msg.sender,
      tokenIn,
      tokenOut,
      amountIn,
      amountOut
    );
  }
}
