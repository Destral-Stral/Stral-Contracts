// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { SwapExecutor } from "src/swap/SwapExecutor.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { SwapModule } from "src/swap/SwapModule.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { MockAggregator } from "fixtures/MockAggregator.sol";
import { MockStaking } from "fixtures/MockStaking.sol";

/// @dev End-to-end user journeys across the swap module and the rest of the wallet:
///      onramp → buy → sell → withdraw, signed (relayed) flows with nonce continuity,
///      multi-wallet fleets sharing one executor, and admin lifecycle around swaps.
contract SwapScenarios is BaseTest {
  SwapExecutor executor;
  MockAggregator aggregator;
  MockERC20 usdc; // input side, alias of BaseTest's allowed `token`
  MockERC20 blue; // blue-chip output side

  function setUp() public override {
    super.setUp();

    usdc = token;
    blue = new MockERC20("Blue Chip", "BLUE");
    coordinator.allowToken(address(blue));

    executor = new SwapExecutor(address(coordinator));
    coordinator.setSwapExecutor(address(executor));

    aggregator = new MockAggregator();
    executor.allowAggregator(address(aggregator));
  }

  function _route(
    MockERC20 tokenIn,
    uint256 spend,
    MockERC20 tokenOut,
    uint256 pay
  ) internal pure returns (bytes memory) {
    return
      abi.encodeCall(
        MockAggregator.swap,
        (tokenIn, spend, tokenOut, pay)
      );
  }

  function _swapDirect(
    SmartWallet wallet,
    address walletOwner,
    MockERC20 tokenIn,
    MockERC20 tokenOut,
    uint256 amountIn,
    uint256 amountOut
  ) internal {
    vm.prank(walletOwner);
    wallet.swap(
      address(tokenIn),
      address(tokenOut),
      amountIn,
      amountOut,
      address(aggregator),
      _route(tokenIn, amountIn, tokenOut, amountOut),
      NO_DEADLINE,
      _directAuth()
    );
  }

  /// @dev Signs a Swap intent with an EOA key and returns the EOASig auth payload.
  function _signSwap(
    uint256 key,
    SmartWallet wallet,
    MockERC20 tokenIn,
    MockERC20 tokenOut,
    uint256 amountIn,
    uint256 minAmountOut
  ) internal view returns (MultiSignerAuth.Auth memory) {
    bytes32 structHash = keccak256(
      abi.encode(
        keccak256(
          "Swap(address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 nonce,uint256 deadline)"
        ),
        address(tokenIn),
        address(tokenOut),
        amountIn,
        minAmountOut,
        wallet.nonce(),
        NO_DEADLINE
      )
    );
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(
      key,
      _walletDigest(address(wallet), structHash)
    );
    return
      MultiSignerAuth.Auth({
        authType: MultiSignerAuth.AuthType.EOASig,
        payload: abi.encodePacked(r, s, v)
      });
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Full user lifecycle
  // ═══════════════════════════════════════════════════════════════════════

  /// @dev Onramp USDC → buy blue chip → sell half back → whitelist → withdraw USDC.
  function test_scenario_onrampBuySellWithdraw() public {
    address owner = makeAddr("lifecycleOwner");
    SmartWallet wallet = _deployWallet(keccak256("lifecycle"), owner);

    // Onramp: 1000 USDC lands in the wallet.
    usdc.mint(address(wallet), 1000 ether);

    // Buy: 600 USDC → 0.3 BLUE.
    _swapDirect(wallet, owner, usdc, blue, 600 ether, 0.3 ether);
    assertEq(usdc.balanceOf(address(wallet)), 400 ether);
    assertEq(blue.balanceOf(address(wallet)), 0.3 ether);

    // Sell: 0.1 BLUE → 190 USDC.
    _swapDirect(wallet, owner, blue, usdc, 0.1 ether, 190 ether);
    assertEq(usdc.balanceOf(address(wallet)), 590 ether);
    assertEq(blue.balanceOf(address(wallet)), 0.2 ether);

    // Withdraw USDC through the whitelist flow (delay applies).
    address bank = makeAddr("bankAccount");
    vm.prank(owner);
    wallet.addToWhitelist(bank, NO_DEADLINE, _directAuth());
    vm.warp(block.timestamp + DELAY);
    vm.prank(owner);
    wallet.withdrawAssets(
      bank,
      address(usdc),
      590 ether,
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(usdc.balanceOf(bank), 590 ether);
    assertEq(usdc.balanceOf(address(wallet)), 0);
    assertEq(blue.balanceOf(address(wallet)), 0.2 ether);
  }

  /// @dev Same journey through the relayed (signed) path: every action authorized by
  ///      EOA signature with strictly increasing nonces, submitted by the relayer.
  function test_scenario_relayedSignedJourney_nonceContinuity()
    public
  {
    uint256 key = uint256(keccak256("relayedUserKey"));
    address sigOwner = vm.addr(key);
    SmartWallet wallet = _deployWallet(
      keccak256("relayed"),
      sigOwner
    );
    address relayer = makeAddr("relayerEOA");

    usdc.mint(address(wallet), 1000 ether);
    assertEq(wallet.nonce(), 0);

    // Buy via signature (nonce 0).
    MultiSignerAuth.Auth memory auth = _signSwap(
      key,
      wallet,
      usdc,
      blue,
      500 ether,
      0.25 ether
    );
    vm.prank(relayer);
    wallet.swap(
      address(usdc),
      address(blue),
      500 ether,
      0.25 ether,
      address(aggregator),
      _route(usdc, 500 ether, blue, 0.25 ether),
      NO_DEADLINE,
      auth
    );
    assertEq(wallet.nonce(), 1);

    // Sell everything back via signature (nonce 1).
    auth = _signSwap(key, wallet, blue, usdc, 0.25 ether, 480 ether);
    vm.prank(relayer);
    wallet.swap(
      address(blue),
      address(usdc),
      0.25 ether,
      480 ether,
      address(aggregator),
      _route(blue, 0.25 ether, usdc, 480 ether),
      NO_DEADLINE,
      auth
    );
    assertEq(wallet.nonce(), 2);
    assertEq(usdc.balanceOf(address(wallet)), 980 ether);
    assertEq(blue.balanceOf(address(wallet)), 0);
  }

  /// @dev Buy the platform staking token via swap, then stake it — cross-module flow.
  function test_scenario_buyThenStakePlatformToken() public {
    address owner = makeAddr("stakerOwner");
    SmartWallet wallet = _deployWallet(keccak256("staker"), owner);

    MockERC20 platformToken = new MockERC20("DEVRAL", "DEVRAL");
    coordinator.allowToken(address(platformToken));
    MockStaking staking = new MockStaking(platformToken);
    coordinator.setStakingToken(address(platformToken));
    coordinator.setStakingContract(address(staking));

    usdc.mint(address(wallet), 100 ether);

    _swapDirect(
      wallet,
      owner,
      usdc,
      platformToken,
      100 ether,
      200 ether
    );
    assertEq(platformToken.balanceOf(address(wallet)), 200 ether);

    vm.prank(owner);
    wallet.stake(200 ether, NO_DEADLINE, _directAuth());
    assertEq(platformToken.balanceOf(address(staking)), 200 ether);
    assertEq(platformToken.balanceOf(address(wallet)), 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Fleet behavior
  // ═══════════════════════════════════════════════════════════════════════

  /// @dev Two wallets interleave swaps through the shared executor without interference.
  function test_scenario_twoWalletsSharedExecutor() public {
    address ownerA = makeAddr("ownerA");
    address ownerB = makeAddr("ownerB");
    SmartWallet walletA = _deployWallet(keccak256("walletA"), ownerA);
    SmartWallet walletB = _deployWallet(keccak256("walletB"), ownerB);

    usdc.mint(address(walletA), 100 ether);
    usdc.mint(address(walletB), 300 ether);

    _swapDirect(walletA, ownerA, usdc, blue, 40 ether, 1 ether);
    _swapDirect(walletB, ownerB, usdc, blue, 200 ether, 5 ether);
    _swapDirect(walletA, ownerA, usdc, blue, 60 ether, 2 ether);

    assertEq(usdc.balanceOf(address(walletA)), 0);
    assertEq(blue.balanceOf(address(walletA)), 3 ether);
    assertEq(usdc.balanceOf(address(walletB)), 100 ether);
    assertEq(blue.balanceOf(address(walletB)), 5 ether);
    assertEq(usdc.balanceOf(address(executor)), 0);
    assertEq(blue.balanceOf(address(executor)), 0);
  }

  /// @dev An owner cannot use their signature on someone else's wallet (domain binding).
  function test_scenario_signatureDoesNotCrossWallets() public {
    uint256 key = uint256(keccak256("crossKey"));
    address sigOwner = vm.addr(key);
    SmartWallet walletA = _deployWallet(
      keccak256("crossA"),
      sigOwner
    );
    SmartWallet walletB = _deployWallet(
      keccak256("crossB"),
      sigOwner
    );

    usdc.mint(address(walletA), 100 ether);
    usdc.mint(address(walletB), 100 ether);

    // Signature bound to walletA's domain must not authorize the same op on walletB.
    MultiSignerAuth.Auth memory auth = _signSwap(
      key,
      walletA,
      usdc,
      blue,
      100 ether,
      1 ether
    );
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    walletB.swap(
      address(usdc),
      address(blue),
      100 ether,
      1 ether,
      address(aggregator),
      _route(usdc, 100 ether, blue, 1 ether),
      NO_DEADLINE,
      auth
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Admin lifecycle around swaps
  // ═══════════════════════════════════════════════════════════════════════

  /// @dev Admin rotates aggregators: old one stops working, new one takes over.
  function test_scenario_aggregatorRotation() public {
    address owner = makeAddr("rotationOwner");
    SmartWallet wallet = _deployWallet(keccak256("rotation"), owner);
    usdc.mint(address(wallet), 200 ether);

    _swapDirect(wallet, owner, usdc, blue, 100 ether, 1 ether);

    MockAggregator newAggregator = new MockAggregator();
    executor.disallowAggregator(address(aggregator));
    executor.allowAggregator(address(newAggregator));

    // Old aggregator now rejected.
    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapExecutor.AggregatorNotAllowed.selector,
        address(aggregator)
      )
    );
    wallet.swap(
      address(usdc),
      address(blue),
      100 ether,
      1 ether,
      address(aggregator),
      _route(usdc, 100 ether, blue, 1 ether),
      NO_DEADLINE,
      _directAuth()
    );

    // New aggregator works.
    vm.prank(owner);
    wallet.swap(
      address(usdc),
      address(blue),
      100 ether,
      1 ether,
      address(newAggregator),
      _route(usdc, 100 ether, blue, 1 ether),
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(blue.balanceOf(address(wallet)), 2 ether);
  }

  /// @dev Token delisted between quote and execution: swap fails, relists: works again.
  function test_scenario_tokenDelistedMidFlight() public {
    address owner = makeAddr("delistOwner");
    SmartWallet wallet = _deployWallet(keccak256("delist"), owner);
    usdc.mint(address(wallet), 100 ether);

    coordinator.disallowToken(address(blue));

    vm.prank(owner);
    vm.expectRevert(
      abi.encodeWithSelector(
        SwapModule.SwapTokenNotAllowed.selector,
        address(blue)
      )
    );
    wallet.swap(
      address(usdc),
      address(blue),
      100 ether,
      1 ether,
      address(aggregator),
      _route(usdc, 100 ether, blue, 1 ether),
      NO_DEADLINE,
      _directAuth()
    );

    coordinator.allowToken(address(blue));
    _swapDirect(wallet, owner, usdc, blue, 100 ether, 1 ether);
    assertEq(blue.balanceOf(address(wallet)), 1 ether);
  }

  /// @dev A blocked wallet cannot swap; unblocking restores it. Withdrawals unaffected.
  function test_scenario_blockedWalletCannotSwapButCanWithdraw()
    public
  {
    address owner = makeAddr("blockedOwner");
    SmartWallet wallet = _deployWallet(keccak256("blocked"), owner);
    usdc.mint(address(wallet), 100 ether);

    // Whitelist a recipient before the block, wait out the delay.
    address rescue = makeAddr("rescue");
    vm.prank(owner);
    wallet.addToWhitelist(rescue, NO_DEADLINE, _directAuth());
    vm.warp(block.timestamp + DELAY);

    coordinator.blockWallet(address(wallet));

    vm.prank(owner);
    vm.expectRevert(SwapModule.WalletBlocked.selector);
    wallet.swap(
      address(usdc),
      address(blue),
      50 ether,
      1 ether,
      address(aggregator),
      _route(usdc, 50 ether, blue, 1 ether),
      NO_DEADLINE,
      _directAuth()
    );

    // Withdrawals are not gated by the block.
    vm.prank(owner);
    wallet.withdrawAssets(
      rescue,
      address(usdc),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(usdc.balanceOf(rescue), 50 ether);

    coordinator.unblockWallet(address(wallet));
    _swapDirect(wallet, owner, usdc, blue, 50 ether, 1 ether);
    assertEq(blue.balanceOf(address(wallet)), 1 ether);
  }
}
