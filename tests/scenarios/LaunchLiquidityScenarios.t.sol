// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";

/// @dev Minimal surface of the Uniswap v3 contracts the launch touches, declared here since the
///      repository carries no Uniswap package. Addresses are the canonical mainnet deployments.
interface IUniswapV3Factory {
  function getPool(
    address tokenA,
    address tokenB,
    uint24 fee
  ) external view returns (address);
}

interface IUniswapV3Pool {
  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      uint8 feeProtocol,
      bool unlocked
    );

  function liquidity() external view returns (uint128);

  function token0() external view returns (address);

  function fee() external view returns (uint24);
}

interface INonfungiblePositionManager {
  struct IncreaseLiquidityParams {
    uint256 tokenId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  struct DecreaseLiquidityParams {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
  }

  function balanceOf(address owner) external view returns (uint256);

  function tokenOfOwnerByIndex(
    address owner,
    uint256 index
  ) external view returns (uint256);

  function positions(
    uint256 tokenId
  )
    external
    view
    returns (
      uint96 nonce,
      address operator,
      address token0,
      address token1,
      uint24 fee,
      int24 tickLower,
      int24 tickUpper,
      uint128 liquidity,
      uint256 feeGrowthInside0LastX128,
      uint256 feeGrowthInside1LastX128,
      uint128 tokensOwed0,
      uint128 tokensOwed1
    );

  function increaseLiquidity(
    IncreaseLiquidityParams calldata params
  ) external payable returns (uint128 liquidity, uint256 amount0, uint256 amount1);

  function decreaseLiquidity(
    DecreaseLiquidityParams calldata params
  ) external payable returns (uint256 amount0, uint256 amount1);

  function collect(
    CollectParams calldata params
  ) external payable returns (uint256 amount0, uint256 amount1);

  function burn(uint256 tokenId) external payable;
}

interface ISwapRouter02 {
  struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
  }

  function exactInputSingle(
    ExactInputSingleParams calldata params
  ) external payable returns (uint256 amountOut);
}

/// @title LaunchLiquidityScenariosBase
/// @notice Replays the treasury Safe batch written by scripts/prepareLaunchLiquidityBatch.ts
///         on a fork of the network, then trades against the pool and reshapes the positions
///         the way the treasury will after launch: buy and sell through the Uniswap router,
///         add and remove liquidity, collect the fees, close a position. Prod is STRAL/usdc on
///         Ethereum, preprod the DEVRAL/usdc rehearsal on Arbitrum; trade sizes follow the
///         amounts of the batch so both run the same scenarios.
/// @dev Skipped unless the network's RPC env var is set AND the batch file exists: the test
///      checks the exact calldata the signers will execute, so it never rebuilds it on its
///      own. Generate it with `npm run liquidity:launch-batch[:preprod]` first. The treasury
///      is topped up with usdc on the fork when it holds less than the batch needs, so the
///      sequence can be rehearsed before the funding transfer.
abstract contract LaunchLiquidityScenariosBase is Test {
  string internal envName; // "prod" | "preprod"
  string internal networkName; // "mainnet" | "arbitrum"
  string internal rpcEnvVar; // e.g. "MAINNET_RPC_URL"
  address internal usdc;

  // Same canonical Uniswap v3 addresses on Ethereum and Arbitrum One.
  address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
  address constant POSITION_MANAGER =
    0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
  address constant SWAP_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
  bytes4 constant CREATE_POOL_SELECTOR = 0x13ead562; // createAndInitializePoolIfNecessary
  bytes4 constant MINT_SELECTOR = 0x88316456; // mint
  uint256 constant NO_DEADLINE = type(uint256).max;

  bool forked;
  address treasury;
  address stral;
  address trader = makeAddr("trader");

  address[] batchTargets;
  bytes[] batchCalldata;
  uint24 fee;
  uint160 launchSqrtPriceX96;
  uint256 mintCount;
  uint256 needed0;
  uint256 needed1;
  bool usdcIsToken0; // Uniswap orders the pair by address: USDC first on Ethereum, not on Arbitrum

  IUniswapV3Pool pool;
  INonfungiblePositionManager positions =
    INonfungiblePositionManager(POSITION_MANAGER);

  function setUp() public {
    string memory rpc = vm.envOr(rpcEnvVar, string(""));
    string memory batchPath = string.concat(
      vm.projectRoot(),
      "/temp/",
      envName,
      "/safe-batch-",
      networkName,
      "-launch-liquidity.json"
    );
    if (bytes(rpc).length == 0 || !vm.exists(batchPath)) return;

    vm.createSelectFork(rpc);
    forked = true;

    string memory record = vm.readFile(
      string.concat(
        vm.projectRoot(),
        "/deployers/deployments/",
        envName,
        "/",
        networkName,
        "/StralToken.json"
      )
    );
    stral = vm.parseJsonAddress(record, ".address");
    treasury = vm.parseJsonAddress(record, ".args[0]");
    usdcIsToken0 = usdc < stral;

    _loadBatch(vm.readFile(batchPath));
    _replayBatch();
  }

  modifier onlyForked() {
    vm.skip(!forked);
    _;
  }

  // ── Batch ──────────────────────────────────────────────────────────────────

  function _loadBatch(string memory json) internal {
    assertEq(
      vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"),
      treasury,
      "batch is not for the treasury"
    );
    for (uint256 i = 0; ; i++) {
      string memory key = string.concat(".transactions[", vm.toString(i), "]");
      if (!vm.keyExistsJson(json, string.concat(key, ".to"))) break;
      address to = vm.parseJsonAddress(json, string.concat(key, ".to"));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, ".data"));
      batchTargets.push(to);
      batchCalldata.push(data);
      _inspect(to, data);
    }
    assertGt(mintCount, 0, "batch mints nothing");
  }

  /// @dev Reads what the batch is about to do, so the checks below know what to expect.
  function _inspect(address to, bytes memory data) internal {
    bytes4 selector = bytes4(data);
    bytes memory args = _args(data);
    if (to == POSITION_MANAGER && selector == CREATE_POOL_SELECTOR) {
      (address token0, address token1, uint24 fee_, uint160 sqrtPriceX96) = abi
        .decode(args, (address, address, uint24, uint160));
      _assertPair(token0, token1);
      fee = fee_;
      launchSqrtPriceX96 = sqrtPriceX96;
    } else if (to == POSITION_MANAGER && selector == MINT_SELECTOR) {
      (
        address token0,
        address token1,
        uint24 fee_,
        ,
        ,
        uint256 amount0Desired,
        uint256 amount1Desired,
        ,
        ,
        address recipient,
        uint256 deadline
      ) = abi.decode(
          args,
          (
            address,
            address,
            uint24,
            int24,
            int24,
            uint256,
            uint256,
            uint256,
            uint256,
            address,
            uint256
          )
        );
      _assertPair(token0, token1);
      assertEq(recipient, treasury, "position is not minted to the treasury");
      assertGt(deadline, block.timestamp, "batch deadline already passed");
      if (fee == 0) fee = fee_;
      else assertEq(fee_, fee, "mint on another fee tier");
      mintCount++;
      needed0 += amount0Desired;
      needed1 += amount1Desired;
    } else if (to == usdc || to == stral) {
      assertEq(selector, IERC20.approve.selector, "unexpected token call");
      (address spender, ) = abi.decode(args, (address, uint256));
      assertEq(spender, POSITION_MANAGER, "approval to another spender");
    } else {
      revert("unexpected call in the batch");
    }
  }

  function _assertPair(address token0, address token1) internal view {
    assertEq(token0, usdcIsToken0 ? usdc : stral, "unexpected token0");
    assertEq(token1, usdcIsToken0 ? stral : usdc, "unexpected token1");
  }

  /// @dev Pool amounts (token0, token1) as (USDC, token).
  function _byToken(
    uint256 amount0,
    uint256 amount1
  ) internal view returns (uint256 usdcAmount, uint256 tokenAmount) {
    return usdcIsToken0 ? (amount0, amount1) : (amount1, amount0);
  }

  function usdcNeeded() internal view returns (uint256) {
    return usdcIsToken0 ? needed0 : needed1;
  }

  function tokenNeeded() internal view returns (uint256) {
    return usdcIsToken0 ? needed1 : needed0;
  }

  function _args(bytes memory data) internal pure returns (bytes memory args) {
    args = new bytes(data.length - 4);
    for (uint256 i = 0; i < args.length; i++) args[i] = data[i + 4];
  }

  /// @dev Sends the batch from the treasury, in order, like the Safe will.
  function _replayBatch() internal {
    uint256 usdcBalance = IERC20(usdc).balanceOf(treasury);
    if (usdcBalance < usdcNeeded()) deal(usdc, treasury, usdcNeeded());

    uint256 positionsBefore = positions.balanceOf(treasury);
    vm.startPrank(treasury);
    for (uint256 i = 0; i < batchTargets.length; i++) {
      (bool ok, bytes memory ret) = batchTargets[i].call(batchCalldata[i]);
      if (!ok) {
        emit log_named_uint("batch call failed at index", i);
        assembly {
          revert(add(ret, 32), mload(ret))
        }
      }
    }
    vm.stopPrank();

    pool = IUniswapV3Pool(IUniswapV3Factory(FACTORY).getPool(usdc, stral, fee));
    assertTrue(address(pool) != address(0), "pool not created");
    assertEq(
      positions.balanceOf(treasury) - positionsBefore,
      mintCount,
      "not every position was minted"
    );
  }

  function _position(uint256 index) internal view returns (uint256 tokenId) {
    uint256 count = positions.balanceOf(treasury);
    return positions.tokenOfOwnerByIndex(treasury, count - mintCount + index);
  }

  function _liquidityOf(uint256 tokenId) internal view returns (uint128 liquidity) {
    (, , , , , , , liquidity, , , , ) = positions.positions(tokenId);
  }

  function _price() internal view returns (uint160 sqrtPriceX96, int24 tick) {
    (sqrtPriceX96, tick, , , , , ) = pool.slot0();
  }

  function _swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
  ) internal returns (uint256 amountOut) {
    vm.startPrank(trader);
    IERC20(tokenIn).approve(SWAP_ROUTER, amountIn);
    amountOut = ISwapRouter02(SWAP_ROUTER).exactInputSingle(
      ISwapRouter02.ExactInputSingleParams({
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        fee: fee,
        recipient: trader,
        amountIn: amountIn,
        amountOutMinimum: 0,
        sqrtPriceLimitX96: 0
      })
    );
    vm.stopPrank();
  }

  // ── Deploy ─────────────────────────────────────────────────────────────────

  function test_batch_createsThePoolAtTheLaunchPrice() public onlyForked {
    (uint160 sqrtPriceX96, ) = _price();
    assertEq(pool.token0(), usdcIsToken0 ? usdc : stral);
    assertEq(pool.fee(), fee);
    if (launchSqrtPriceX96 != 0) assertEq(sqrtPriceX96, launchSqrtPriceX96);
    assertGt(pool.liquidity(), 0, "no liquidity active at the launch price");
  }

  function test_batch_mintsEachPositionOnOneSideOfTheLaunchPrice() public onlyForked {
    (, int24 tick) = _price();
    for (uint256 i = 0; i < mintCount; i++) {
      (, , , , , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = positions
        .positions(_position(i));
      assertGt(liquidity, 0, "empty position");
      assertTrue(
        tickLower >= tick || tickUpper <= tick,
        "position straddles the launch price"
      );
    }
  }

  function test_batch_leavesNoDanglingAllowance() public onlyForked {
    // Mints pull what they need; what is left is rounding dust, never a usable allowance.
    assertLt(IERC20(usdc).allowance(treasury, POSITION_MANAGER), 1e6);
    assertLt(IERC20(stral).allowance(treasury, POSITION_MANAGER), 1e18);
  }

  // ── Swap ───────────────────────────────────────────────────────────────────

  function test_swap_buyStralWithUsdcMovesThePriceUp() public onlyForked {
    (, int24 tickBefore) = _price();
    uint256 amount = usdcNeeded() / 20;
    deal(usdc, trader, amount);

    uint256 received = _swap(usdc, stral, amount);

    (, int24 tickAfter) = _price();
    assertGt(received, 0, "no STRAL received");
    assertEq(IERC20(stral).balanceOf(trader), received);
    // The pool tick follows token1 per token0: buying the token moves it down when USDC is
    // token0, up otherwise.
    if (usdcIsToken0) assertLt(tickAfter, tickBefore, "price did not move");
    else assertGt(tickAfter, tickBefore, "price did not move");
  }

  function test_swap_sellStralForUsdcMovesThePriceDown() public onlyForked {
    (, int24 tickBefore) = _price();
    uint256 amount = tokenNeeded() / 100;
    deal(stral, trader, amount);

    uint256 received = _swap(stral, usdc, amount);

    (, int24 tickAfter) = _price();
    assertGt(received, 0, "no USDC received");
    if (usdcIsToken0) assertGt(tickAfter, tickBefore, "price did not move");
    else assertLt(tickAfter, tickBefore, "price did not move");
  }

  function test_swap_roundTripLosesOnlyFeesAndSlippage() public onlyForked {
    uint256 amount = usdcNeeded() / 200;
    deal(usdc, trader, amount);
    uint256 bought = _swap(usdc, stral, amount);
    uint256 back = _swap(stral, usdc, bought);

    assertLt(back, amount, "round trip cannot be free");
    // Two 0.3 % legs plus the price impact of a small trade on the launch liquidity.
    assertGt(back, (amount * 98) / 100, "round trip lost more than fees and slippage");
  }

  // ── Positions ──────────────────────────────────────────────────────────────

  function test_positions_treasuryCollectsTheFeesOfTheTrades() public onlyForked {
    uint256 amount = usdcNeeded() / 4;
    deal(usdc, trader, amount);
    uint256 bought = _swap(usdc, stral, amount);
    _swap(stral, usdc, bought);

    uint256 usdcBefore = IERC20(usdc).balanceOf(treasury);
    uint256 stralBefore = IERC20(stral).balanceOf(treasury);
    uint256 collected0;
    uint256 collected1;
    vm.startPrank(treasury);
    for (uint256 i = 0; i < mintCount; i++) {
      (uint256 amount0, uint256 amount1) = positions.collect(
        INonfungiblePositionManager.CollectParams({
          tokenId: _position(i),
          recipient: treasury,
          amount0Max: type(uint128).max,
          amount1Max: type(uint128).max
        })
      );
      collected0 += amount0;
      collected1 += amount1;
    }
    vm.stopPrank();

    assertGt(collected0 + collected1, 0, "no fees collected");
    (uint256 usdcOut, uint256 stralOut) = _byToken(collected0, collected1);
    assertEq(IERC20(usdc).balanceOf(treasury), usdcBefore + usdcOut);
    assertEq(IERC20(stral).balanceOf(treasury), stralBefore + stralOut);
  }

  function test_positions_treasuryAddsLiquidityToAnExistingPosition() public onlyForked {
    uint256 tokenId = _position(0);
    uint128 liquidityBefore = _liquidityOf(tokenId);
    uint256 more0 = needed0 / 10;
    uint256 more1 = needed1 / 10;
    deal(usdc, treasury, IERC20(usdc).balanceOf(treasury) + usdcNeeded() / 10);

    vm.startPrank(treasury);
    IERC20(usdc).approve(POSITION_MANAGER, usdcNeeded() / 10);
    IERC20(stral).approve(POSITION_MANAGER, tokenNeeded() / 10);
    (uint128 added, , ) = positions.increaseLiquidity(
      INonfungiblePositionManager.IncreaseLiquidityParams({
        tokenId: tokenId,
        amount0Desired: more0,
        amount1Desired: more1,
        amount0Min: 0,
        amount1Min: 0,
        deadline: NO_DEADLINE
      })
    );
    vm.stopPrank();

    assertGt(added, 0);
    assertEq(_liquidityOf(tokenId), liquidityBefore + added);
  }

  function test_positions_treasuryRemovesHalfThenClosesAPosition() public onlyForked {
    uint256 tokenId = _position(mintCount - 1);
    uint128 liquidityBefore = _liquidityOf(tokenId);
    uint256 usdcBefore = IERC20(usdc).balanceOf(treasury);
    uint256 stralBefore = IERC20(stral).balanceOf(treasury);

    vm.startPrank(treasury);
    positions.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: liquidityBefore / 2,
        amount0Min: 0,
        amount1Min: 0,
        deadline: NO_DEADLINE
      })
    );
    assertEq(_liquidityOf(tokenId), liquidityBefore - liquidityBefore / 2);

    positions.decreaseLiquidity(
      INonfungiblePositionManager.DecreaseLiquidityParams({
        tokenId: tokenId,
        liquidity: _liquidityOf(tokenId),
        amount0Min: 0,
        amount1Min: 0,
        deadline: NO_DEADLINE
      })
    );
    (uint256 amount0, uint256 amount1) = positions.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId,
        recipient: treasury,
        amount0Max: type(uint128).max,
        amount1Max: type(uint128).max
      })
    );
    assertEq(_liquidityOf(tokenId), 0);
    positions.burn(tokenId);
    vm.stopPrank();

    assertGt(amount0 + amount1, 0, "nothing came back");
    (uint256 usdcOut, uint256 stralOut) = _byToken(amount0, amount1);
    assertEq(IERC20(usdc).balanceOf(treasury), usdcBefore + usdcOut);
    assertEq(IERC20(stral).balanceOf(treasury), stralBefore + stralOut);
    assertEq(positions.balanceOf(treasury), mintCount - 1);
  }
}

contract LaunchLiquidityProdMainnetScenarios is LaunchLiquidityScenariosBase {
  constructor() {
    envName = "prod";
    networkName = "mainnet";
    rpcEnvVar = "MAINNET_RPC_URL";
    usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  }
}

contract LaunchLiquidityPreprodArbitrumScenarios is LaunchLiquidityScenariosBase {
  constructor() {
    envName = "preprod";
    networkName = "arbitrum";
    rpcEnvVar = "ARBITRUM_RPC_URL";
    usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
  }
}
