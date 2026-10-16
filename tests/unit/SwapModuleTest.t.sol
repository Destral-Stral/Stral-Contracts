// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { SwapExecutor } from "src/swap/SwapExecutor.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { SwapModule } from "src/swap/SwapModule.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { MockWETH } from "fixtures/MockWETH.sol";
import { MockAggregator } from "fixtures/MockAggregator.sol";

contract SwapModuleTest is BaseTest {
  SmartWallet wallet;
  address owner = makeAddr("owner");
  bytes32 constant USER_ID = keccak256("swapUser");

  SwapExecutor executor;
  MockAggregator aggregator;
  MockERC20 tokenOut;

  uint256 constant AMOUNT_IN = 100 ether;
  uint256 constant AMOUNT_OUT = 50 ether;

  function setUp() public override {
    super.setUp();
    wallet = _deployWallet(USER_ID, owner);

    // `token` (from BaseTest) is the input token and is already on the allowlist.
    tokenOut = new MockERC20("Blue Chip", "BLUE");
    coordinator.allowToken(address(tokenOut));

    executor = new SwapExecutor(address(coordinator));
    coordinator.setSwapExecutor(address(executor));

    aggregator = new MockAggregator();
    executor.allowAggregator(address(aggregator));

    token.mint(address(wallet), AMOUNT_IN);
  }

  /// @dev Aggregator calldata that spends `spend` of `token` and pays `pay` of `tokenOut`.
  function _routeData(
    uint256 spend,
    uint256 pay
  ) internal view returns (bytes memory) {
    return
      abi.encodeCall(
        MockAggregator.swap,
        (token, spend, tokenOut, pay)
      );
  }

  /// @dev EIP-712 struct hash mirroring SwapModule's private SWAP_TYPEHASH.
  function _swapStructHash(
    uint256 amountIn,
    uint256 minAmountOut,
    uint256 nonce,
    uint256 deadline
  ) internal view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "Swap(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint256 deadline)"
          ),
          address(token),
          address(tokenOut),
          amountIn,
          minAmountOut,
          nonce,
          deadline
        )
      );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  swap — happy paths
  // ═══════════════════════════════════════════════════════════════════════

  function test_swap_direct_swapsTokens() public {
    vm.prank(owner);
    uint256 amountOut = wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(amountOut, AMOUNT_OUT);
    assertEq(token.balanceOf(address(wallet)), 0);
    assertEq(tokenOut.balanceOf(address(wallet)), AMOUNT_OUT);
  }

  function test_swap_direct_emitsEvent() public {
    vm.prank(owner);
    vm.expectEmit(true, true, false, true, address(wallet));
    emit SwapModule.Swapped(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_executorHoldsNothingAfterSwap() public {
    vm.prank(owner);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(token.balanceOf(address(executor)), 0);
    assertEq(tokenOut.balanceOf(address(executor)), 0);
  }

  function test_swap_refundsUnspentTokenIn() public {
    // Route only spends half of amountIn; leftover must return to the wallet.
    vm.prank(owner);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN / 2, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(token.balanceOf(address(wallet)), AMOUNT_IN / 2);
    assertEq(tokenOut.balanceOf(address(wallet)), AMOUNT_OUT);
    assertEq(token.balanceOf(address(executor)), 0);
  }

  function test_swap_eoaSig_swapsAndIncrementsNonce() public {
    uint256 ownerKey = uint256(keccak256("swapOwnerKey"));
    address sigOwner = vm.addr(ownerKey);
    SmartWallet w = _deployWallet(
      keccak256("sigSwapWallet"),
      sigOwner
    );
    token.mint(address(w), AMOUNT_IN);

    bytes32 digest = _walletDigest(
      address(w),
      _swapStructHash(AMOUNT_IN, AMOUNT_OUT, 0, NO_DEADLINE)
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);

    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    w.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      auth
    );

    assertEq(tokenOut.balanceOf(address(w)), AMOUNT_OUT);
    assertEq(w.nonce(), 1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  swap — auth failures
  // ═══════════════════════════════════════════════════════════════════════

  function test_swap_revertsIfNotOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_eoaSig_revertsOnReplay() public {
    uint256 ownerKey = uint256(keccak256("swapOwnerKey"));
    address sigOwner = vm.addr(ownerKey);
    SmartWallet w = _deployWallet(
      keccak256("replayWallet"),
      sigOwner
    );
    token.mint(address(w), AMOUNT_IN * 2);

    bytes32 digest = _walletDigest(
      address(w),
      _swapStructHash(AMOUNT_IN / 2, 0, 0, NO_DEADLINE)
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    w.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN / 2,
      0,
      address(aggregator),
      _routeData(AMOUNT_IN / 2, AMOUNT_OUT),
      NO_DEADLINE,
      auth
    );

    // Same signature again — nonce moved on, so recovery mismatches.
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    w.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN / 2,
      0,
      address(aggregator),
      _routeData(AMOUNT_IN / 2, AMOUNT_OUT),
      NO_DEADLINE,
      auth
    );
  }

  function test_swap_eoaSig_revertsIfExpired() public {
    uint256 ownerKey = uint256(keccak256("swapOwnerKey"));
    address sigOwner = vm.addr(ownerKey);
    SmartWallet w = _deployWallet(
      keccak256("expiredWallet"),
      sigOwner
    );
    token.mint(address(w), AMOUNT_IN);

    uint256 deadline = block.timestamp - 1;
    bytes32 digest = _walletDigest(
      address(w),
      _swapStructHash(AMOUNT_IN, AMOUNT_OUT, 0, deadline)
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
    MultiSignerAuth.Auth memory auth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    vm.expectRevert(
      abi.encodeWithSelector(
        MultiSignerAuth.SignatureExpired.selector,
        deadline
      )
    );
    w.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      deadline,
      auth
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  swap — native ETH (wrapped into WETH)
  // ═══════════════════════════════════════════════════════════════════════

  function test_swap_eth_wrapsAndSwaps() public {
    MockWETH weth = new MockWETH();
    coordinator.setWeth(address(weth));
    coordinator.allowToken(address(weth));
    vm.deal(address(wallet), 3 ether);

    vm.prank(owner);
    uint256 amountOut = wallet.swap(
      address(0),
      address(tokenOut),
      2 ether,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(
        MockAggregator.swap,
        (weth, 1.5 ether, tokenOut, AMOUNT_OUT)
      ),
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(amountOut, AMOUNT_OUT);
    assertEq(tokenOut.balanceOf(address(wallet)), AMOUNT_OUT);
    assertEq(address(wallet).balance, 1 ether);
    // Unspent input is refunded as WETH.
    assertEq(weth.balanceOf(address(wallet)), 0.5 ether);
  }

  function test_swap_eth_revertsIfWethNotSet() public {
    vm.deal(address(wallet), 1 ether);

    vm.prank(owner);
    vm.expectRevert(SwapModule.WethNotSet.selector);
    wallet.swap(
      address(0),
      address(tokenOut),
      1 ether,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_eth_revertsIfWethNotAllowed() public {
    MockWETH weth = new MockWETH();
    coordinator.setWeth(address(weth));
    vm.deal(address(wallet), 1 ether);

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapModule.SwapTokenNotAllowed.selector,
        address(weth)
      )
    );
    wallet.swap(
      address(0),
      address(tokenOut),
      1 ether,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_eth_revertsIfInsufficientEth() public {
    MockWETH weth = new MockWETH();
    coordinator.setWeth(address(weth));
    coordinator.allowToken(address(weth));
    vm.deal(address(wallet), 1 ether);

    vm.prank(owner);
    vm.expectRevert();
    wallet.swap(
      address(0),
      address(tokenOut),
      2 ether,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  swap — guard failures
  // ═══════════════════════════════════════════════════════════════════════

  function test_swap_revertsIfTokenInNotAllowed() public {
    MockERC20 rogue = new MockERC20("Rogue", "RGE");
    rogue.mint(address(wallet), AMOUNT_IN);

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapModule.SwapTokenNotAllowed.selector,
        address(rogue)
      )
    );
    wallet.swap(
      address(rogue),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfTokenOutNotAllowed() public {
    MockERC20 rogue = new MockERC20("Rogue", "RGE");

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapModule.SwapTokenNotAllowed.selector,
        address(rogue)
      )
    );
    wallet.swap(
      address(token),
      address(rogue),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfWalletBlocked() public {
    coordinator.blockWallet(address(wallet));

    vm.prank(owner);
    vm.expectRevert(SwapModule.WalletBlocked.selector);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfExecutorNotSet() public {
    coordinator.setSwapExecutor(address(0));

    vm.prank(owner);
    vm.expectRevert(SwapModule.SwapExecutorNotSet.selector);
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfAggregatorNotAllowed() public {
    MockAggregator rogueAgg = new MockAggregator();

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.AggregatorNotAllowed.selector,
        address(rogueAgg)
      )
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(rogueAgg),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfSameToken() public {
    vm.prank(owner);
    vm.expectRevert(SwapExecutor.SameToken.selector);
    wallet.swap(
      address(token),
      address(token),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      "",
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_revertsIfInsufficientOutput() public {
    // Route pays less than minAmountOut.
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.InsufficientOutput.selector,
        AMOUNT_OUT - 1,
        AMOUNT_OUT
      )
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT - 1),
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_swap_bubblesAggregatorRevert() public {
    vm.prank(owner);
    vm.expectRevert("AGGREGATOR_FAILED");
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      abi.encodeCall(MockAggregator.alwaysReverts, ()),
      NO_DEADLINE,
      _directAuth()
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  SwapExecutor — admin
  // ═══════════════════════════════════════════════════════════════════════

  function test_allowAggregator_revertsIfNotOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(SwapExecutor.NotOwner.selector);
    executor.allowAggregator(makeAddr("target"));
  }

  function test_disallowAggregator_revertsIfNotOwner() public {
    vm.prank(makeAddr("stranger"));
    vm.expectRevert(SwapExecutor.NotOwner.selector);
    executor.disallowAggregator(address(aggregator));
  }

  function test_allowDisallowAggregator_updatesList() public {
    address extra = makeAddr("extraAgg");
    executor.allowAggregator(extra);

    address[] memory list = executor.getAllowedAggregators();
    assertEq(list.length, 2);
    assertTrue(executor.allowedAggregators(extra));

    executor.disallowAggregator(extra);
    list = executor.getAllowedAggregators();
    assertEq(list.length, 1);
    assertEq(list[0], address(aggregator));
    assertFalse(executor.allowedAggregators(extra));
  }

  function test_disallowedAggregator_blocksSwap() public {
    executor.disallowAggregator(address(aggregator));

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.AggregatorNotAllowed.selector,
        address(aggregator)
      )
    );
    wallet.swap(
      address(token),
      address(tokenOut),
      AMOUNT_IN,
      AMOUNT_OUT,
      address(aggregator),
      _routeData(AMOUNT_IN, AMOUNT_OUT),
      NO_DEADLINE,
      _directAuth()
    );
  }
}
