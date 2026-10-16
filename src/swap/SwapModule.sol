// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
// Libs
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";
// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";
import { ISwapExecutor } from "src/interfaces/ISwapExecutor.sol";
import { IWETH } from "src/interfaces/IWETH.sol";

/// @title SwapModule
/// @notice Abstract module adding aggregator token swaps to the SmartWallet. The user signs
///         a swap intent (tokens, amounts, minimum output) via EIP-712; the relayer supplies
///         the aggregator target and calldata from an off-chain quote. On-chain guards —
///         coordinator token allowlist, the executor's aggregator allowlist, and
///         `minAmountOut` — bound what any route can do, so the route itself is not signed
///         and can be re-quoted without a new signature.
/// @dev Deliberately stateless: SmartWallet proxies are live behind a beacon, and this module
///      sits before SmartWallet's own variables in the storage layout — adding storage here
///      would shift existing wallets' slots. All configuration is read from the coordinator.
///
///      The arbitrary aggregator call is delegated to the shared SwapExecutor so it never
///      executes with the wallet as `msg.sender`.
abstract contract SwapModule is MultiSignerAuth {
  using SafeERC20 for IERC20;

  // ====== ERRORS ====== //

  error SwapTokenNotAllowed(address token);
  error SwapExecutorNotSet();
  error WalletBlocked();
  error WethNotSet();

  // ====== EVENTS ====== //

  event Swapped(
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut
  );

  // ====== TYPE HASHES ====== //

  bytes32 private constant SWAP_TYPEHASH =
    keccak256(
      "Swap(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint256 deadline)"
    );

  // ====== INTERNALS ====== //

  /// @dev Coordinator accessor implemented by the inheriting wallet. Keeps this module
  ///      free of storage.
  function _coordinator()
    internal
    view
    virtual
    returns (ISmartWalletCoordinator);

  /// @dev Wraps `amount` of the wallet's native ETH into the coordinator's WETH and returns
  ///      the WETH address, so ETH (passed as the zero address) can flow through ERC-20 paths.
  function _wrapEth(
    ISmartWalletCoordinator coordinator_,
    uint256 amount
  ) internal returns (address weth) {
    weth = coordinator_.weth();
    if (weth == address(0)) revert WethNotSet();
    IWETH(weth).deposit{ value: amount }();
  }

  /// @dev EIP-712 struct hash for {swap}. The aggregator target and calldata are not part
  ///      of the signed intent — see the contract-level note.
  function _hashSwap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    uint256 deadline
  ) private view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          SWAP_TYPEHASH,
          tokenIn,
          tokenOut,
          amountIn,
          minAmountOut,
          nonce,
          deadline
        )
      );
  }

  // ====== WRITE FUNCTIONS ====== //

  /// @notice Swaps `amountIn` of `tokenIn` held by this wallet for at least `minAmountOut`
  ///         of `tokenOut` through an allowlisted aggregator route.
  /// @dev Both tokens must be on the coordinator's allowlist and the wallet must not be
  ///      blocked. The executor pulls `tokenIn`, runs the route, and returns proceeds and
  ///      any unspent input to this wallet. A zero `tokenIn` sells native ETH: `amountIn` is
  ///      first wrapped into the coordinator's WETH, which must itself be allowlisted, and
  ///      any unspent input comes back as WETH.
  /// @param tokenIn      ERC-20 token to sell, or the zero address for native ETH.
  /// @param tokenOut     ERC-20 token to buy.
  /// @param amountIn     Amount of `tokenIn` to sell.
  /// @param minAmountOut Minimum acceptable amount of `tokenOut` (slippage bound).
  /// @param target       Aggregator router, supplied by the relayer from the quote.
  /// @param data         Raw aggregator calldata, supplied by the relayer from the quote.
  /// @param deadline     Timestamp after which a signed authorization is no longer valid.
  /// @param auth         Owner credentials.
  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address target,
    bytes calldata data,
    uint256 deadline,
    Auth calldata auth
  )
    external
    onlyUser(
      auth,
      _hashSwap(tokenIn, tokenOut, amountIn, minAmountOut, deadline),
      deadline
    )
    returns (uint256 amountOut)
  {
    amountOut = _swap(
      tokenIn,
      tokenOut,
      amountIn,
      minAmountOut,
      target,
      data
    );
  }

  /// @dev Body of {swap}, kept apart so `deadline` and `auth` are off the stack while it
  ///      runs: inlined, the function is too deep to compile without the IR pipeline.
  function _swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address target,
    bytes calldata data
  ) private returns (uint256 amountOut) {
    ISmartWalletCoordinator coordinator_ = _coordinator();
    if (tokenIn == address(0))
      tokenIn = _wrapEth(coordinator_, amountIn);
    if (!coordinator_.isTokenAllowed(tokenIn))
      revert SwapTokenNotAllowed(tokenIn);
    if (!coordinator_.isTokenAllowed(tokenOut))
      revert SwapTokenNotAllowed(tokenOut);
    if (coordinator_.isBlocked(address(this)))
      revert WalletBlocked();

    address executor = coordinator_.swapExecutor();
    if (executor == address(0)) revert SwapExecutorNotSet();

    IERC20(tokenIn).forceApprove(executor, amountIn);
    amountOut = ISwapExecutor(executor).executeSwap(
      tokenIn,
      tokenOut,
      amountIn,
      minAmountOut,
      target,
      data
    );

    emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
  }
}
