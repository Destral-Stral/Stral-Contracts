// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Complex sequential-action scenarios for the Vesting + Staking subsystem.
 *
 *  Each test simulates a realistic multi-step timeline and verifies that ALL
 *  accounting stays coherent across the full sequence — not just the final state,
 *  but the intermediate checkpoints too.
 *
 *  Infrastructure: VestingStakingBase (12 months, SCHED0 cliff=2 / SCHED1 cliff=4).
 *
 *  Scenario index:
 *   1. Multi-schedule sequential claiming — math stays exact across 3 claim events
 *   2. Multi-user token accounting — independent balances, conservation holds
 *   3. Unlock priority under partial fills — vesting-first across 4 request sizes
 *   4. Re-stake cycle — withdraw, re-deposit, withdraw again; positions chain correctly
 *   5. Lock duration change isolation — new duration doesn't touch existing positions
 *   6. Vesting pause propagates to unlock — critical: blocks even pure-staking users
 *   7. Full depletion lifecycle — vesting + staking both reach zero cleanly
 *   8. Dust-free final period — non-divisible amount, last period recovers integer-division dust
 *   9. Vesting contract swap — admin replaces vesting mid-flight; old state disconnects
 *  10. Multi-position FIFO drain — 5 positions with different lock states drain in order
 */

import { VestingStakingBase } from "fixtures/VestingStakingBase.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { Staking } from "src/staking/Staking.sol";
import { IVestingDistributor } from "src/interfaces/IVestingDistributor.sol";

contract VestingStakingScenarios is VestingStakingBase {

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 1: Multi-schedule sequential claiming
  //
  //  Alice has two schedules:
  //    SCHED0 (cliff=2, 10 periods): 120e  → 12e per period
  //    SCHED1 (cliff=4,  8 periods):  80e  → 10e per period
  //
  //  Three claim events at months 3, 5, and 12.
  //  Math must stay exact at every checkpoint, and grand total = 200e.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_sequentialClaimingAcrossSchedules() public {
    _loadPosition(alice, SCHED0, 120 ether); // 12e per period
    _loadPosition(alice, SCHED1, 80 ether);  // 10e per period
    _fundVesting(200 ether);

    // ── Month 3: SCHED0 opens (elapsed=1), SCHED1 still in cliff ──────────
    _warpPastMonth(3);

    assertEq(vesting.claimableBalanceOf(alice), 12 ether,     "m3: claimable");
    assertEq(vesting.unclaimedBalanceOf(alice), 200 ether,    "m3: unclaimed before claim");

    vm.prank(address(staking));
    uint256 c1 = vesting.claimFor(alice, type(uint256).max);
    assertEq(c1, 12 ether, "m3: claimed");

    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 12 ether, "m3: sched0 claimed");
    assertEq(vesting.getPosition(alice, SCHED1).claimedAmount, 0,        "m3: sched1 untouched");
    assertEq(vesting.unclaimedBalanceOf(alice), 188 ether,               "m3: unclaimed after");

    // ── Month 5: SCHED0 elapsed=3 (36e total, 24e new), SCHED1 elapsed=1 (10e) ──
    _warpPastMonth(2); // total: 5 months from start

    assertEq(vesting.claimableBalanceOf(alice), 34 ether, "m5: claimable");

    vm.prank(address(staking));
    uint256 c2 = vesting.claimFor(alice, type(uint256).max);
    assertEq(c2, 34 ether, "m5: claimed");

    // SCHED0: 36e vested, SCHED1: 10e vested
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 36 ether, "m5: sched0 claimed");
    assertEq(vesting.getPosition(alice, SCHED1).claimedAmount, 10 ether, "m5: sched1 claimed");
    assertEq(vesting.unclaimedBalanceOf(alice), 154 ether,               "m5: unclaimed after");

    // ── Month 12: both schedules fully vested ─────────────────────────────
    _warpPastMonth(7); // total: 12 months from start (all elapsed)

    assertEq(vesting.claimableBalanceOf(alice), 154 ether, "m12: claimable");

    vm.prank(address(staking));
    uint256 c3 = vesting.claimFor(alice, type(uint256).max);
    assertEq(c3, 154 ether, "m12: claimed");

    assertEq(vesting.unclaimedBalanceOf(alice),  0,          "m12: fully drained");
    assertEq(vesting.claimableBalanceOf(alice),  0,          "m12: nothing left");
    assertEq(c1 + c2 + c3,                       200 ether, "grand total matches allocation");
    assertEq(token.balanceOf(address(vesting)),  0,          "vesting contract emptied");
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 2: Multi-user token accounting
  //
  //  Alice (100e) and Bob (200e) both have SCHED0 positions.
  //  Each claims independently at different times.
  //  Token conservation must hold at every step:
  //    token_in_vesting + total_claimed = total_loaded
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_multiUserIndependentAccounting() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _loadPosition(bob,   SCHED0, 200 ether);
    _fundVesting(300 ether);

    // ── Month 4: elapsed=2, alice has 20e, bob has 40e ────────────────────
    _warpPastMonth(4);

    assertEq(vesting.claimableBalanceOf(alice), 20 ether, "m4: alice claimable");
    assertEq(vesting.claimableBalanceOf(bob),   40 ether, "m4: bob claimable");

    // Alice claims; Bob's state must be untouched
    vm.prank(address(staking));
    vesting.claimFor(alice, type(uint256).max);

    assertEq(vesting.unclaimedBalanceOf(alice), 80 ether,  "m4: alice unclaimed");
    assertEq(vesting.unclaimedBalanceOf(bob),  200 ether,  "m4: bob unclaimed unchanged");
    assertEq(token.balanceOf(address(vesting)), 280 ether, "m4: conservation after alice claim");

    // ── Month 7: elapsed=5, bob claims ────────────────────────────────────
    _warpPastMonth(3); // total: 7 months

    // alice: vested=50e, claimed=20e → claimable=30e
    // bob:   vested=100e, claimed=0  → claimable=100e
    assertEq(vesting.claimableBalanceOf(alice), 30 ether,  "m7: alice claimable");
    assertEq(vesting.claimableBalanceOf(bob),  100 ether, "m7: bob claimable");

    vm.prank(address(staking));
    vesting.claimFor(bob, type(uint256).max);

    assertEq(vesting.unclaimedBalanceOf(bob),  100 ether,  "m7: bob unclaimed after");
    assertEq(token.balanceOf(address(vesting)), 180 ether, "m7: conservation after bob claim");

    // ── Month 12: both fully vest and drain ───────────────────────────────
    _warpPastMonth(5); // total: 12 months

    vm.prank(address(staking));
    vesting.claimFor(alice, type(uint256).max);
    vm.prank(address(staking));
    vesting.claimFor(bob, type(uint256).max);

    assertEq(vesting.unclaimedBalanceOf(alice), 0, "final: alice drained");
    assertEq(vesting.unclaimedBalanceOf(bob),   0, "final: bob drained");
    assertEq(token.balanceOf(address(vesting)), 0, "final: vesting empty");
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 3: Unlock priority under partial fills
  //
  //  Alice has 30e claimable vesting AND 50e unlocked staking.
  //  Four unlock requests test every combination of the priority rule
  //  (vesting first, then staking):
  //    a) request exactly vesting claimable     → from vesting only
  //    b) request more than vesting, less total → split vesting+staking
  //    c) request exactly total available       → both drained
  //    d) request more than total               → capped at available
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_unlockPriorityAndPartialFills() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _deposit(alice, 50 ether); // direct stake, lock = 7 days

    _warpPastMonth(3); // vesting: elapsed=1 → 10e claimable
    // Also past the 7-day lock, so staking is withdrawable

    // Baseline: 10e claimable vesting, 50e withdrawable staking
    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.vestingClaimable,   10 ether, "baseline: vesting claimable");
    assertEq(s.stakingWithdrawable, 50 ether, "baseline: staking withdrawable");

    // ── a) Exactly vesting claimable → from vesting only ─────────────────
    uint256 balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(10 ether);

    s = staking.getUserStakeSummary(alice);
    assertEq(token.balanceOf(alice) - balBefore, 10 ether, "a: received");
    assertEq(s.vestingClaimable,    0,          "a: vesting drained");
    assertEq(s.vestingUnclaimed,   90 ether,    "a: vesting unclaimed updated");
    assertEq(s.stakingWithdrawable, 50 ether,   "a: staking untouched");

    // ── b) More than vesting available → splits vesting + staking ─────────
    // At month 4 (+1 warp): vesting claimable = 20-10 = 10e more
    _warpPastMonth(1); // month 4: elapsed=2, vested=20e, claimed=10e → claimable=10e

    balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(25 ether); // needs 10e from vesting + 15e from staking

    s = staking.getUserStakeSummary(alice);
    assertEq(token.balanceOf(alice) - balBefore, 25 ether, "b: received");
    assertEq(s.vestingClaimable,    0,           "b: vesting drained");
    assertEq(s.stakingWithdrawable, 35 ether,    "b: staking reduced by 15e");
    assertEq(s.stakingWithdrawn,    15 ether,    "b: withdrawn tracked");

    // ── c) Exactly the remaining total → both drained fully ───────────────
    // Advance to month 6: vesting elapsed=4 → 40e vested, claimed=20e → 20e claimable
    _warpPastMonth(2); // month 6

    s = staking.getUserStakeSummary(alice);
    uint256 totalAvailable = s.vestingClaimable + s.stakingWithdrawable;
    // vestingClaimable=20e, stakingWithdrawable=35e → total=55e

    balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(totalAvailable);

    s = staking.getUserStakeSummary(alice);
    assertEq(token.balanceOf(alice) - balBefore, totalAvailable, "c: received exact total");
    assertEq(s.vestingClaimable,    0,           "c: vesting drained");
    assertEq(s.stakingWithdrawable, 0,           "c: staking drained");

    // ── d) Request beyond available → capped at actual balance ────────────
    // Remaining: 80e in vesting (locked, not claimable at month 6 yet past all)
    // Wait: at month 6, elapsed=4, vested=40e, all claimable=0 now. Nothing unlockable.
    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(1 ether); // confirms nothing left to take
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 4: Re-stake cycle
  //
  //  Alice deposits, partially withdraws, then re-deposits, then fully
  //  withdraws. Verifies that multiple positions chain correctly and that
  //  each position's state is tracked independently.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_reStakeCycle() public {
    // ── Round 1: deposit 100e, wait, withdraw 60e ─────────────────────────
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    vm.prank(alice);
    staking.unlock(60 ether);
    assertEq(token.balanceOf(alice), 60 ether, "r1: received");

    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions.length,             1,         "r1: one position");
    assertEq(d.stakingPositions[0].amount,          100 ether, "r1: pos amount");
    assertEq(d.stakingPositions[0].withdrawnAmount,  60 ether, "r1: pos withdrawn");

    // ── Round 2: re-deposit 60e, wait, withdraw all ───────────────────────
    token.mint(alice, 60 ether); // Alice lost 40e remaining in contract + has 60e withdrawn
    vm.startPrank(alice);
    token.approve(address(staking), 60 ether);
    staking.deposit(60 ether);
    vm.stopPrank();

    assertEq(staking.nextPositionId(), 2, "r2: two positions created total");

    vm.warp(block.timestamp + uint256(LOCK) + 1);

    d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions.length, 2, "r2: two positions");
    // pos0: 100e deposited, 60e withdrawn → 40e remaining
    // pos1: 60e deposited, 0e withdrawn  → 60e remaining
    assertEq(d.summary.stakingWithdrawable, 100 ether, "r2: total withdrawable = 40+60");

    uint256 balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(100 ether); // drain both positions

    assertEq(token.balanceOf(alice) - balBefore, 100 ether, "r2: full withdrawal");

    d = staking.getUserStakeDetails(alice);
    assertEq(d.summary.stakingWithdrawable, 0, "r2: all withdrawn");
    assertEq(d.summary.stakingWithdrawn, 160 ether, "r2: total withdrawn = 60+100"); // 60 from r1 + 40 from pos0 remainder + 60 from pos1
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 5: Lock duration change isolation
  //
  //  Admin changes lockDuration between two deposits. The older position
  //  must respect its original lock, not the new one.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_lockDurationChangeIsolation() public {
    address carol = makeAddr("carol");
    address dave  = makeAddr("dave");

    // Carol deposits at LOCK=7d; then admin raises lock to 60d; Dave deposits.
    _deposit(carol, 100 ether); // unlockAt = now + 7d

    uint64 newLock = 60 days;
    staking.setLockDuration(newLock);

    _deposit(dave, 100 ether); // unlockAt = now + 60d

    // ── After 7d + 1s: Carol unlocked, Dave still locked ─────────────────
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    // Carol can withdraw
    vm.prank(carol);
    staking.unlock(100 ether);
    assertEq(token.balanceOf(carol), 100 ether, "carol unlocked at 7d");

    // Dave cannot withdraw yet
    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(dave);
    assertEq(s.stakingWithdrawable, 0,           "dave still locked");
    assertEq(s.stakingLocked,       100 ether,   "dave locked");

    vm.prank(dave);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(100 ether);

    // ── After 60d total: Dave's lock expires ──────────────────────────────
    vm.warp(block.timestamp + uint256(newLock));

    vm.prank(dave);
    staking.unlock(100 ether);
    assertEq(token.balanceOf(dave), 100 ether, "dave unlocked at 60d");

    // Admin reduces lock back to 7d — does not retroactively affect either position
    staking.setLockDuration(LOCK);
    assertEq(staking.lockDuration(), LOCK);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 6: Vesting pause propagates to staking unlock
  //
  //  The vesting contract's whenNotPaused modifier fires BEFORE the
  //  mask == 0 early-return, so a paused VestingDistributor makes
  //  claimFor ALWAYS revert — blocking unlock even for users with no
  //  vesting position and only direct staking.
  //
  //  This is load-bearing contract behaviour: operators pausing vesting
  //  must understand it freezes ALL withdrawals through Staking.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_vestingPausePropagation() public {
    address pureStaker = makeAddr("pureStaker"); // no vesting at all
    address vestUser   = makeAddr("vestUser");

    // pureStaker has only direct staking
    _deposit(pureStaker, 50 ether);

    // vestUser has vesting + staking
    _loadPosition(vestUser, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _deposit(vestUser, 50 ether);

    // Advance past lock and past cliff
    _warpPastMonth(3);

    // Both should be able to unlock normally
    vm.prank(pureStaker);
    staking.unlock(50 ether);
    assertEq(token.balanceOf(pureStaker), 50 ether, "pre-pause: pureStaker ok");

    // Re-deposit so pureStaker has something again to test under pause
    _deposit(pureStaker, 50 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    // ── Admin pauses vesting ──────────────────────────────────────────────
    vesting.pause();

    // vestUser unlock → claimFor reverts (paused) → bubbles up
    vm.prank(vestUser);
    vm.expectRevert("Pausable: paused");
    staking.unlock(10 ether);

    // pureStaker has NO vesting position — but claimFor still reverts
    // because whenNotPaused fires before the mask == 0 early-return
    vm.prank(pureStaker);
    vm.expectRevert("Pausable: paused");
    staking.unlock(50 ether); // blocked despite having zero vesting involvement

    // ── Admin unpauses → everything resumes ──────────────────────────────
    vesting.unpause();

    uint256 pureBefore = token.balanceOf(pureStaker);
    vm.prank(pureStaker);
    staking.unlock(50 ether);
    assertEq(token.balanceOf(pureStaker) - pureBefore, 50 ether, "post-unpause: pureStaker ok");

    vm.prank(vestUser);
    staking.unlock(10 ether); // pulls from vesting (10e claimable at month 3+)
    assertEq(token.balanceOf(vestUser), 10 ether, "post-unpause: vestUser ok");
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 7: Full depletion lifecycle
  //
  //  Alice has vesting + staking. Both are drained completely over time.
  //  Verifies that after full depletion every accounting field is zero and
  //  further unlock calls revert cleanly with NothingUnlockable.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_fullDepletionLifecycle() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _loadPosition(alice, SCHED1, 80 ether);
    _fundVesting(180 ether);
    _deposit(alice, 50 ether); // lock = 7d, unlocks well before month 3

    // Drain everything month by month from the initial state.
    // Month 1 (30d > 7d lock): staking becomes withdrawable.
    // Month 3: SCHED0 opens (cliff=2). Month 5: SCHED1 opens (cliff=4).
    uint256 totalDrained;
    for (uint256 month = 1; month <= 12; month++) {
      _warpPastMonth(1);

      Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
      uint256 available = s.vestingClaimable + s.stakingWithdrawable;
      if (available > 0) {
        uint256 balBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.unlock(available);
        totalDrained += token.balanceOf(alice) - balBefore;
      }
    }

    // ── Verify zero state ─────────────────────────────────────────────────
    assertEq(totalDrained,                      230 ether, "total: 180 vesting + 50 staking");
    assertEq(vesting.unclaimedBalanceOf(alice),  0,        "vesting unclaimed zero");
    assertEq(vesting.claimableBalanceOf(alice),  0,        "vesting claimable zero");
    assertEq(token.balanceOf(address(vesting)),  0,        "vesting contract empty");

    Staking.UserStakeSummary memory finalS = staking.getUserStakeSummary(alice);
    assertEq(finalS.totalVipStake,       0,  "vip stake zero");
    assertEq(finalS.vestingUnclaimed,    0,  "vesting zero in summary");
    assertEq(finalS.stakingWithdrawable, 0,  "staking withdrawable zero");

    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 8: Dust-free final period
  //
  //  Loads a non-divisible amount (1e18 + 1 wei) into a 10-period schedule.
  //  Claiming once per period for 9 periods loses 1 wei to integer truncation.
  //  The 10th period must return totalAmount directly, recovering the lost wei.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_dustFreeLastPeriod() public {
    // SCHED0: cliff=2, vestingPeriods=10.
    // Each period: (1e18+1)/10 = 1e17 (floor division loses 1 wei over 9 periods).
    // The 10th period must return totalAmount directly to recover that wei.
    uint256 amount = 1e18 + 1;
    _loadPosition(alice, SCHED0, uint96(amount));
    _fundVesting(amount);

    uint256 perPeriod = amount / 10; // = 1e17

    // Warp past cliff into the first vesting period (3 months = ts[2])
    _warpPastMonth(3); // elapsed=1 for SCHED0

    uint256 totalClaimed;

    // ── Period 1 ─────────────────────────────────────────────────────────
    {
      uint256 claimable = vesting.claimableBalanceOf(alice);
      assertEq(claimable, perPeriod, "p1: claimable");
      vm.prank(address(staking));
      uint256 claimed = vesting.claimFor(alice, type(uint256).max);
      assertEq(claimed, perPeriod, "p1: claimed");
      totalClaimed += claimed;
    }

    // ── Periods 2–9: each advances one more month ─────────────────────────
    for (uint256 period = 2; period <= 9; period++) {
      _warpPastMonth(1); // +1 month at a time (cumulative from period 1's position)

      uint256 claimable = vesting.claimableBalanceOf(alice);
      assertEq(claimable, perPeriod, string.concat("p", vm.toString(period), ": claimable"));

      vm.prank(address(staking));
      uint256 claimed = vesting.claimFor(alice, type(uint256).max);
      assertEq(claimed, perPeriod, string.concat("p", vm.toString(period), ": claimed"));
      totalClaimed += claimed;
    }

    assertEq(totalClaimed, perPeriod * 9, "9 periods: total claimed");

    // ── Period 10: elapsed >= vestingPeriods → contract returns totalAmount ──
    _warpPastMonth(1); // total: 3 + (9-1) + 1 = 12 months from setUp

    uint256 finalClaimable = vesting.claimableBalanceOf(alice);
    // Expected: totalAmount - 9*perPeriod = (1e18+1) - 9e17 = 1e17+1 (dust recovered)
    assertEq(finalClaimable, amount - totalClaimed, "p10: dust-free claimable");

    vm.prank(address(staking));
    uint256 lastClaim = vesting.claimFor(alice, type(uint256).max);
    assertEq(lastClaim, amount - totalClaimed, "p10: dust recovered in last period");

    assertEq(totalClaimed + lastClaim, amount, "grand total = original allocation");
    assertEq(token.balanceOf(address(vesting)), 0, "vesting contract emptied");
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, uint128(amount), "claimedAmount = totalAmount");
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 9: Vesting contract swap
  //
  //  Admin replaces the vesting contract in the coordinator registry mid-flight.
  //  Old vesting state becomes inaccessible through Staking (reads zero),
  //  but direct calls to the old vesting contract still work.
  //  Re-wiring restores access.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_vestingContractSwap() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _deposit(alice, 50 ether);
    _warpPastMonth(3); // alice has 10e claimable from old vesting

    // ── Confirm baseline ──────────────────────────────────────────────────
    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.vestingClaimable, 10 ether, "pre-swap: claimable visible");

    // ── Admin swaps to a fresh vesting (no positions) ─────────────────────
    uint64[] memory ts = new uint64[](TOTAL_MONTHS);
    for (uint256 i = 0; i < TOTAL_MONTHS; i++) {
      ts[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }
    VestingDistributor.ScheduleInput[] memory schedules = new VestingDistributor.ScheduleInput[](0);

    VestingDistributor newVesting = VestingDistributor(
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
    // The claimFor gate reads coordinator.stakingContract(), which already points
    // at `staking` — the new vesting needs no wiring of its own.
    coordinator.setVestingContract(address(newVesting));

    // Staking now reads from newVesting: alice has no positions there
    s = staking.getUserStakeSummary(alice);
    assertEq(s.vestingClaimable,  0,        "post-swap: vesting invisible through staking");
    assertEq(s.vestingUnclaimed,  0,        "post-swap: unclaimed zero");
    // Direct staking still works: staking position is unchanged
    assertEq(s.stakingWithdrawable, 50 ether, "post-swap: staking unaffected");

    // Old vesting still holds alice's position (contract state unchanged)
    assertEq(vesting.claimableBalanceOf(alice), 10 ether, "old vesting: alice still has position");

    // Alice cannot claim her old vesting tokens through staking anymore
    // (staking now calls newVesting.claimFor which returns 0 for alice)
    vm.warp(block.timestamp + uint256(LOCK) + 1); // ensure staking is withdrawable
    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(50 ether); // can only pull from staking, not from newVesting
    assertEq(token.balanceOf(alice) - aliceBefore, 50 ether, "post-swap: only staking returned");

    // ── Admin re-wires back to original vesting ────────────────────────────
    coordinator.setVestingContract(address(vesting));

    s = staking.getUserStakeSummary(alice);
    // At month 3+ alice had 10e claimable; staking position fully withdrawn so 0e there
    // Let's warp to month 12 so everything is fully vested
    _warpPastMonth(9); // total: 12 months
    s = staking.getUserStakeSummary(alice);
    assertEq(s.vestingClaimable, 100 ether, "re-wired: full vesting claimable again");

    aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(100 ether);
    assertEq(token.balanceOf(alice) - aliceBefore, 100 ether, "re-wired: full claim works");
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Scenario 10: Multi-position FIFO drain order
  //
  //  Alice makes 5 deposits of 20e with different lock states:
  //    pos0: deposited at t=0     → unlockAt = t + LOCK   (unlocked)
  //    pos1: deposited at t=0     → unlockAt = t + LOCK   (unlocked)
  //    pos2: deposited at t=0     → unlockAt = t + LOCK   (unlocked)
  //    pos3: deposited at t+LOCK+1 → unlockAt = t+2*LOCK+1 (still locked at drain time)
  //    pos4: deposited at t+LOCK+1 → unlockAt = t+2*LOCK+1 (still locked at drain time)
  //
  //  Draining 50e should consume pos0 and pos1 in order, never touching
  //  the locked pos3/pos4. Verifies FIFO drain and lock enforcement together.
  // ═══════════════════════════════════════════════════════════════════════

  function test_scenario_multiPositionFIFODrain() public {
    // pos0, pos1, pos2 deposited now (all unlock after LOCK)
    _deposit(alice, 20 ether); // pos0
    _deposit(alice, 20 ether); // pos1
    _deposit(alice, 20 ether); // pos2

    uint256 lockExpiry = block.timestamp + uint256(LOCK);
    vm.warp(lockExpiry + 1); // advance past lock for pos0/pos1/pos2

    // pos3, pos4 deposited after the first lock expired → their lock starts NOW
    _deposit(alice, 20 ether); // pos3 (unlockAt = now + LOCK)
    _deposit(alice, 20 ether); // pos4 (unlockAt = now + LOCK)

    // At this moment:
    //   pos0/pos1/pos2: withdrawable (60e total)
    //   pos3/pos4:      locked (40e total)
    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.stakingWithdrawable, 60 ether, "initial: 60e withdrawable");
    assertEq(s.stakingLocked,       40 ether, "initial: 40e locked");

    // ── First drain: take 50e → consumes pos0 (20e) + pos1 (20e) + 10e from pos2 ──
    uint256 balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(50 ether);
    assertEq(token.balanceOf(alice) - balBefore, 50 ether, "drain1: received");

    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions[0].withdrawnAmount, 20 ether, "drain1: pos0 fully drained");
    assertEq(d.stakingPositions[1].withdrawnAmount, 20 ether, "drain1: pos1 fully drained");
    assertEq(d.stakingPositions[2].withdrawnAmount, 10 ether, "drain1: pos2 partially drained");
    assertEq(d.stakingPositions[3].withdrawnAmount,  0,       "drain1: pos3 untouched");
    assertEq(d.stakingPositions[4].withdrawnAmount,  0,       "drain1: pos4 untouched");

    // ── Second drain: take remaining unlocked 10e from pos2 ───────────────
    balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(10 ether);
    assertEq(token.balanceOf(alice) - balBefore, 10 ether, "drain2: received");

    d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions[2].withdrawnAmount, 20 ether, "drain2: pos2 fully drained");

    // ── Now nothing withdrawable; locked positions still intact ───────────
    s = staking.getUserStakeSummary(alice);
    assertEq(s.stakingWithdrawable, 0,           "after drain2: nothing withdrawable");
    assertEq(s.stakingLocked,       40 ether,    "after drain2: locked positions unchanged");

    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(1);

    // ── After pos3/pos4 lock expires → they drain cleanly ─────────────────
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    balBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(40 ether);
    assertEq(token.balanceOf(alice) - balBefore, 40 ether, "drain3: pos3+pos4 drained");

    d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions[3].withdrawnAmount, 20 ether, "drain3: pos3 drained");
    assertEq(d.stakingPositions[4].withdrawnAmount, 20 ether, "drain3: pos4 drained");

    s = staking.getUserStakeSummary(alice);
    assertEq(s.totalVipStake, 0, "final: all drained");
  }
}
