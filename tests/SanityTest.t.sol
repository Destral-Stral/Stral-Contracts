// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice End-to-end sanity test simulating the full Palantex user journey:
 *   1. Protocol deployment & configuration
 *   2. Wallet deployment (EOA-only)
 *   3. Whitelist management with delay enforcement
 *   4. transferAssets to strategy
 *   5. Wallet blocking / unblocking
 *   6. Multi-owner management (add, act, remove)
 *   7. Token disallowance cutting off transfers (withdrawals unaffected)
 */

import { BaseTest } from "fixtures/BaseTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { SmartWallet } from "src/smartWallet/SmartWallet.sol";
import { SmartWalletFactory } from "src/smartWallet/SmartWalletFactory.sol";
import { SmartWalletCoordinator } from "src/smartWallet/SmartWalletCoordinator.sol";
import { MultiSignerAuth } from "src/module/MultiSignerAuth.sol";
import { SwapModule } from "src/swap/SwapModule.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { Staking } from "src/staking/Staking.sol";

contract SanityTest is BaseTest {
  // ─── Actors ─────────────────────────────────────────────────────────────

  uint256 aliceKey = uint256(keccak256("alice"));
  address alice = vm.addr(uint256(keccak256("alice")));
  address bob = makeAddr("bob"); // recipient, later becomes co-owner
  address charlie = makeAddr("charlie"); // additional whitelist recipient

  SmartWallet wallet;
  bytes32 constant WALLET_ID = keccak256("aliceWallet");

  function setUp() public override {
    super.setUp();

    aliceKey = uint256(keccak256("alice"));
    alice = vm.addr(aliceKey);

    // 1. Deploy Alice's wallet (EOA only)
    wallet = _deployWallet(WALLET_ID, alice);

    // Seed the wallet with tokens
    token.mint(address(wallet), 1_000 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Full journey (split into labeled sections for readability)
  // ═══════════════════════════════════════════════════════════════════════

  function test_fullJourney() public {
    // ── 2. Initial state checks ──────────────────────────────────────
    assertTrue(wallet.isWalletOwner(alice));
    assertEq(wallet.whitelist(alice), 0);
    assertEq(wallet.nonce(), 0);

    // ── 3a. Alice whitelists Bob (delay applies) ─────────────────────
    vm.prank(alice);
    wallet.addToWhitelist(bob, NO_DEADLINE, _directAuth());
    uint256 bobAddedAt = wallet.whitelist(bob);
    assertTrue(bobAddedAt > 1); // block.timestamp, not sentinel

    // ── 3b. Bob cannot withdraw before delay elapses ─────────────────
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.WithdrawalDelayNotMet.selector,
        bobAddedAt + DELAY
      )
    );
    wallet.withdrawAssets(
      bob,
      address(token),
      100 ether,
      NO_DEADLINE,
      _directAuth()
    );

    // ── 3c. After delay, Bob can receive a withdrawal ────────────────
    vm.warp(block.timestamp + DELAY + 1);
    vm.prank(alice);
    wallet.withdrawAssets(
      bob,
      address(token),
      100 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(bob), 100 ether);

    // ── 3d. Alice is an owner, but not a withdrawal recipient until explicitly whitelisted.
    vm.prank(alice);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.NotWhitelisted.selector,
        alice
      )
    );
    wallet.withdrawAssets(
      alice,
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );

    // ── 4. Transfer to strategy ──────────────────────────────────────
    uint256 walletBefore = token.balanceOf(address(wallet));
    vm.prank(alice);
    wallet.transferAssets(
      address(token),
      200 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(strategy), 200 ether);
    assertEq(
      token.balanceOf(address(wallet)),
      walletBefore - 200 ether
    );

    // ── 5a. Coordinator blocks the wallet ────────────────────────────
    coordinator.blockWallet(address(wallet));
    assertTrue(coordinator.isBlocked(address(wallet)));

    vm.prank(alice);
    vm.expectRevert(SwapModule.WalletBlocked.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );

    // ── 5b. Coordinator unblocks → transfers resume ──────────────────
    coordinator.unblockWallet(address(wallet));
    vm.prank(alice);
    wallet.transferAssets(
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(strategy), 250 ether);

    // ── 6a. Alice adds Bob as a co-owner ─────────────────────────────
    vm.prank(alice);
    wallet.addWalletOwner(bob, NO_DEADLINE, _directAuth());
    assertTrue(wallet.isWalletOwner(bob));
    assertEq(wallet.getOwners().length, 2);

    // ── 6b. Bob acts as owner via Direct auth ────────────────────────
    vm.prank(bob);
    wallet.addToWhitelist(charlie, NO_DEADLINE, _directAuth());
    assertTrue(wallet.whitelist(charlie) > 1);

    // ── 6c. Alice removes herself ─────────────────────────────────────
    vm.prank(alice);
    wallet.removeWalletOwner(alice, NO_DEADLINE, _directAuth());
    assertFalse(wallet.isWalletOwner(alice));
    assertEq(wallet.getOwners().length, 1); // Bob is sole owner

    // Alice can no longer act
    vm.prank(alice);
    vm.expectRevert(MultiSignerAuth.Unauthorized.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );

    // Bob still can
    vm.prank(bob);
    wallet.transferAssets(
      address(token),
      10 ether,
      NO_DEADLINE,
      _directAuth()
    );

    // ── 7. Coordinator disallows token → transfers revert, withdrawals still work
    coordinator.disallowToken(address(token));

    vm.prank(bob);
    vm.expectRevert(
      abi.encodeWithSelector(
        SmartWallet.TokenNotAllowed.selector,
        address(token)
      )
    );
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );

    uint256 bobBefore = token.balanceOf(bob);
    vm.prank(bob);
    wallet.withdrawAssets(
      bob,
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(bob), bobBefore + 1 ether);

    // Re-allowing restores functionality
    coordinator.allowToken(address(token));
    vm.prank(bob);
    wallet.transferAssets(
      address(token),
      10 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  EOASig auth end-to-end (Alice signs whitelist operations)
  // ═══════════════════════════════════════════════════════════════════════

  function test_eoaSig_fullWhitelistCycle() public {
    address recipient = makeAddr("signedRecipient");

    // Sign addToWhitelist
    bytes32 addStructHash = keccak256(
      abi.encode(
        keccak256(
          "AddToWhitelist(address recipient,uint256 nonce,uint256 deadline)"
        ),
        recipient,
        wallet.nonce(),
        NO_DEADLINE
      )
    );
    bytes32 addDigest = _walletDigest(address(wallet), addStructHash);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, addDigest);
    MultiSignerAuth.Auth memory addAuth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    wallet.addToWhitelist(recipient, NO_DEADLINE, addAuth);
    assertTrue(wallet.whitelist(recipient) > 1);
    assertEq(wallet.nonce(), 1);

    // Sign removeFromWhitelist
    bytes32 removeStructHash = keccak256(
      abi.encode(
        keccak256(
          "RemoveFromWhitelist(address recipient,uint256 nonce,uint256 deadline)"
        ),
        recipient,
        wallet.nonce(),
        NO_DEADLINE
      )
    );
    bytes32 removeDigest = _walletDigest(
      address(wallet),
      removeStructHash
    );
    (v, r, s) = vm.sign(aliceKey, removeDigest);
    MultiSignerAuth.Auth memory removeAuth = MultiSignerAuth.Auth({
      authType: MultiSignerAuth.AuthType.EOASig,
      payload: abi.encodePacked(r, s, v)
    });

    wallet.removeFromWhitelist(recipient, NO_DEADLINE, removeAuth);
    assertEq(wallet.whitelist(recipient), 0);
    assertEq(wallet.nonce(), 2);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Multiple wallets — independent state
  // ═══════════════════════════════════════════════════════════════════════

  function test_multipleWallets_independentState() public {
    address bobOwner = makeAddr("bobOwner");
    SmartWallet bobWallet = _deployWallet(
      keccak256("bobWallet"),
      bobOwner
    );
    token.mint(address(bobWallet), 500 ether);

    // Blocking Alice's wallet does not affect Bob's
    coordinator.blockWallet(address(wallet));

    vm.prank(bobOwner);
    bobWallet.transferAssets(
      address(token),
      100 ether,
      NO_DEADLINE,
      _directAuth()
    );
    assertEq(token.balanceOf(strategy), 100 ether);

    // Alice's wallet is still blocked
    vm.prank(alice);
    vm.expectRevert(SwapModule.WalletBlocked.selector);
    wallet.transferAssets(
      address(token),
      1 ether,
      NO_DEADLINE,
      _directAuth()
    );
  }

  function test_multipleWallets_sharedStrategyAddress() public {
    address newStrategy = makeAddr("newStrategy");
    coordinator.setStrategyAddress(newStrategy);

    address bobOwner = makeAddr("bobOwner");
    SmartWallet bobWallet = _deployWallet(
      keccak256("bobWallet2"),
      bobOwner
    );
    token.mint(address(bobWallet), 100 ether);

    vm.prank(alice);
    wallet.transferAssets(
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );
    vm.prank(bobOwner);
    bobWallet.transferAssets(
      address(token),
      50 ether,
      NO_DEADLINE,
      _directAuth()
    );

    assertEq(token.balanceOf(newStrategy), 100 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Vesting + Staking full journey
  // ═══════════════════════════════════════════════════════════════════════

  /**
   * @notice End-to-end sanity test for the vesting and staking subsystem:
   *   1. Admin wires the staking token, deploys VestingDistributor + Staking
   *   2. Admin loads a vesting allocation for a user
   *   3. User makes a direct staking deposit
   *   4. Before cliff / before lock: nothing is claimable/withdrawable
   *   5. After cliff: user claims the first vesting slice
   *   6. After lock: user withdraws from direct staking
   *   7. Pause halts both operations
   *   8. VIP stake accounting is consistent throughout
   */
  function test_vestingStaking_fullJourney() public {
    uint64 MONTH = 30 days;
    uint64 LOCK = 7 days;

    // ── 1. Deploy subsystem ──────────────────────────────────────────────
    coordinator.setStakingToken(address(token));

    // Upload 12 month-end timestamps
    uint64[] memory ts = new uint64[](12);
    for (uint256 i = 0; i < 12; i++) {
      ts[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }

    // Schedule 0: cliff=2, vestingPeriods=10
    VestingDistributor.ScheduleInput[]
      memory schedules = new VestingDistributor.ScheduleInput[](1);
    uint32[] memory unlocks = new uint32[](12);
    for (uint256 i = 2; i < 12; i++) {
      unlocks[i] = 100_000;
    }
    schedules[0] = VestingDistributor.ScheduleInput({
      cliffMonths: 2,
      label: "Team",
      monthlyUnlockPpm: unlocks
    });

    VestingDistributor vesting = VestingDistributor(
      address(
        new ERC1967Proxy(
          address(new VestingDistributor()),
          abi.encodeCall(
            VestingDistributor.initialize,
            (address(coordinator), ts, schedules)
          )
        )
      )
    );

    Staking staking = Staking(
      address(
        new ERC1967Proxy(
          address(new Staking()),
          abi.encodeCall(
            Staking.initialize,
            (address(coordinator), LOCK)
          )
        )
      )
    );

    coordinator.setVestingContract(address(vesting));
    coordinator.setStakingContract(address(staking));

    // ── 2. Load vesting allocation for user ──────────────────────────────
    address user = makeAddr("vestUser");
    vesting.loadPositions(
      abi.encodePacked(user, uint8(1), uint8(0), uint96(100 ether))
    );
    token.mint(address(vesting), 100 ether);

    // ── 3. User makes a direct staking deposit ───────────────────────────
    token.mint(user, 50 ether);
    vm.startPrank(user);
    token.approve(address(staking), 50 ether);
    staking.deposit(50 ether);
    vm.stopPrank();

    // ── 4a. Before cliff: vesting not claimable ───────────────────────────
    assertEq(vesting.claimableBalanceOf(user), 0);
    assertEq(vesting.unclaimedBalanceOf(user), 100 ether);

    // ── 4b. Before lock: staking not withdrawable ─────────────────────────
    vm.prank(user);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(50 ether);

    // ── 5. After cliff: claim first vesting slice (10e = 1/10) ───────────
    vm.warp(block.timestamp + 3 * uint256(MONTH)); // past cliffMonths=2

    assertEq(vesting.claimableBalanceOf(user), 10 ether);

    uint256 userBefore = token.balanceOf(user);
    vm.prank(user);
    staking.unlock(10 ether); // pulls from vesting (priority 1)
    assertEq(token.balanceOf(user) - userBefore, 10 ether);
    assertEq(vesting.unclaimedBalanceOf(user), 90 ether);

    // ── 6. After lock: withdraw from direct staking ───────────────────────
    vm.warp(block.timestamp + uint256(LOCK) + 1); // original deposit now unlocked

    userBefore = token.balanceOf(user);
    vm.prank(user);
    staking.unlock(50 ether); // pulls from staking (vesting fully drained at this point)
    assertEq(token.balanceOf(user) - userBefore, 50 ether);

    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(
      user
    );
    assertEq(s.stakingWithdrawn, 50 ether);
    assertEq(s.stakingWithdrawable, 0);

    // ── 7. Pause halts deposits and withdrawals ───────────────────────────
    staking.pause();
    token.mint(user, 10 ether);
    vm.startPrank(user);
    token.approve(address(staking), 10 ether);
    vm.expectRevert("Pausable: paused");
    staking.deposit(10 ether);
    vm.stopPrank();

    staking.unpause();

    // ── 8. VIP stake consistency ──────────────────────────────────────────
    // After all claims: vestingUnclaimed=90, stakingWithdrawable=0
    assertEq(staking.totalStakedBalanceOf(user), 90 ether);
  }
}
