// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { VestingStakingBase } from "fixtures/VestingStakingBase.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { IVestingDistributor } from "src/interfaces/IVestingDistributor.sol";
import { RevertingERC20 } from "fixtures/AdversarialTokens.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";

contract VestingTest is VestingStakingBase {

  // ═══════════════════════════════════════════════════════════════════════
  //  Admin setup
  // ═══════════════════════════════════════════════════════════════════════

  function test_setMonthTimestamps_replacesArray() public view {
    assertEq(vesting.monthTimestampsLength(), TOTAL_MONTHS);
    assertEq(vesting.monthTimestamps(0), block.timestamp + MONTH);
    assertEq(vesting.monthTimestamps(TOTAL_MONTHS - 1), block.timestamp + TOTAL_MONTHS * MONTH);
  }

  function test_setMonthTimestamps_mustBeStrictlyIncreasing() public {
    uint64[] memory bad = new uint64[](3);
    bad[0] = 1000;
    bad[1] = 1000; // duplicate — not strictly increasing
    bad[2] = 2000;
    vm.expectRevert(VestingDistributor.InvalidTimestamps.selector);
    vesting.setMonthTimestamps(bad);
  }

  function test_setMonthTimestamps_revert_empty() public {
    uint64[] memory empty = new uint64[](0);
    vm.expectRevert(VestingDistributor.InvalidTimestamps.selector);
    vesting.setMonthTimestamps(empty);
  }

  function test_setMonthTimestamps_revert_lengthChangeWithUnlockCurves() public {
    uint64[] memory shortened = new uint64[](TOTAL_MONTHS - 1);
    for (uint256 i = 0; i < shortened.length; i++) {
      shortened[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }

    vm.expectRevert(VestingDistributor.InvalidUnlockCurve.selector);
    vesting.setMonthTimestamps(shortened);
  }

  function test_addSchedule_registersCorrectly() public view {
    assertEq(vesting.scheduleCount(), 2);
    IVestingDistributor.VestingSchedule memory s = vesting.getSchedule(SCHED0);
    assertEq(s.cliffMonths, 2);
    assertEq(s.active, true);
    assertEq(s.label, "Cliff-2");
  }

  function test_addSchedule_revert_limitReached() public {
    // 2 already added; push to 8
    for (uint8 i = 2; i < 8; i++) {
      vesting.addSchedule(1, "x");
    }
    assertEq(vesting.scheduleCount(), 8);
    vm.expectRevert(VestingDistributor.ScheduleLimitReached.selector);
    vesting.addSchedule(1, "overflow");
  }

  function test_addSchedule_revert_cliffZero() public {
    vm.expectRevert(VestingDistributor.InvalidSchedule.selector);
    vesting.addSchedule(0, "bad");
  }

  function test_addSchedule_revert_cliffTooLarge() public {
    // cliffMonths must be < monthTimestamps.length (12)
    vm.expectRevert(VestingDistributor.InvalidSchedule.selector);
    vesting.addSchedule(uint8(TOTAL_MONTHS), "bad");
  }

  function test_addScheduleWithUnlocks_registersNonLinearCurve() public {
    uint32[] memory curve = _nonLinearCurve();

    vesting.addScheduleWithUnlocks(2, "Non-linear", curve);

    IVestingDistributor.VestingSchedule memory s = vesting.getSchedule(2);
    assertEq(s.cliffMonths, 2);
    assertEq(s.active, true);
    assertEq(s.label, "Non-linear");
    assertEq(s.cumulativeUnlockPpm.length, TOTAL_MONTHS);
    assertEq(s.cumulativeUnlockPpm[1], 0);
    assertEq(s.cumulativeUnlockPpm[2], 100_000);
    assertEq(s.cumulativeUnlockPpm[3], 400_000);
    assertEq(s.cumulativeUnlockPpm[11], 1_000_000);
  }

  function test_addScheduleWithUnlocks_revert_invalidTotal() public {
    uint32[] memory curve = _nonLinearCurve();
    curve[11] -= 1;

    vm.expectRevert(VestingDistributor.InvalidUnlockCurve.selector);
    vesting.addScheduleWithUnlocks(2, "bad", curve);
  }

  function test_addScheduleWithUnlocks_revert_wrongCurveLength() public {
    uint32[] memory wrong = new uint32[](TOTAL_MONTHS + 1);
    wrong[TOTAL_MONTHS] = 1_000_000;
    vm.expectRevert(VestingDistributor.InvalidUnlockCurve.selector);
    vesting.addScheduleWithUnlocks(2, "bad", wrong);
  }

  function test_addScheduleWithUnlocks_revert_cumulativeExceedsDenominator() public {
    uint32[] memory curve = new uint32[](TOTAL_MONTHS);
    curve[2] = 600_000;
    curve[3] = 600_000; // cumulative = 1_200_000 > 1_000_000
    vm.expectRevert(VestingDistributor.InvalidUnlockCurve.selector);
    vesting.addScheduleWithUnlocks(2, "bad", curve);
  }

  function test_addScheduleWithUnlocks_revert_unlockBeforeCliff() public {
    uint32[] memory curve = _nonLinearCurve();
    curve[1] = 1;
    curve[11] -= 1;

    vm.expectRevert(VestingDistributor.InvalidUnlockCurve.selector);
    vesting.addScheduleWithUnlocks(2, "bad", curve);
  }

  function test_setScheduleActive_deactivates() public {
    vesting.setScheduleActive(SCHED0, false);
    assertFalse(vesting.getSchedule(SCHED0).active);

    // loadPositions should now revert for SCHED0
    vm.expectRevert(VestingDistributor.ScheduleNotActive.selector);
    vesting.loadPositions(_packPosition(alice, SCHED0, 1 ether));
  }

  function test_setScheduleActive_reactivates() public {
    vesting.setScheduleActive(SCHED0, false);
    vesting.setScheduleActive(SCHED0, true);
    assertTrue(vesting.getSchedule(SCHED0).active);
    _loadPosition(alice, SCHED0, 10 ether); // should not revert
  }

  function test_setScheduleActive_revert_invalidType() public {
    vm.expectRevert(VestingDistributor.InvalidScheduleType.selector);
    vesting.setScheduleActive(5, true); // only 0 and 1 exist
  }

  function test_claimForGate_followsCoordinator() public {
    address newStaking = makeAddr("newStaking");
    coordinator.setStakingContract(newStaking);

    // The previous staking contract is no longer trusted…
    vm.prank(address(staking));
    vm.expectRevert(VestingDistributor.NotStakingContract.selector);
    vesting.claimFor(alice, 1 ether);

    // …and the one registered in the coordinator is.
    vm.prank(newStaking);
    vesting.claimFor(alice, 1 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Access control
  // ═══════════════════════════════════════════════════════════════════════

  function test_adminFunctions_revert_nonOwner() public {
    address rando = makeAddr("rando");
    vm.startPrank(rando);

    uint64[] memory ts = new uint64[](1);
    ts[0] = 999999;
    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.setMonthTimestamps(ts);

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.addSchedule(1, "x");

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.addScheduleWithUnlocks(1, "x", new uint32[](0));

    vm.expectRevert(VestingDistributor.NotLoaderOrCoordinatorOwner.selector);
    vesting.loadPositions("");

    vm.expectRevert(VestingDistributor.NotLoaderOrCoordinatorOwner.selector);
    vesting.setLoader(rando);

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.setScheduleActive(SCHED0, false);

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.withdrawToken(address(token), rando, 1);

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.pause();

    vm.expectRevert(VestingDistributor.NotCoordinatorOwner.selector);
    vesting.unpause();

    vm.stopPrank();
  }

  function test_loader_initializedToProxyDeployer() public {
    assertEq(vesting.loader(), address(this));
  }

  function test_loader_canLoadAndBeRotatedIndependently() public {
    address newLoader = makeAddr("newLoader");
    vesting.setLoader(newLoader);
    assertEq(vesting.loader(), newLoader);

    // The loader can load without being the coordinator owner…
    vm.prank(newLoader);
    vesting.loadPositions(_packPosition(alice, SCHED0, 1 ether));
    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 1 ether);

    // …and once revoked by the coordinator owner it no longer can.
    vesting.setLoader(address(0));
    vm.prank(newLoader);
    vm.expectRevert(VestingDistributor.NotLoaderOrCoordinatorOwner.selector);
    vesting.loadPositions(_packPosition(alice, SCHED0, 1 ether));
  }

  function test_claimFor_revert_nonStaking() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(3); // past cliff

    vm.prank(makeAddr("notStaking"));
    vm.expectRevert(VestingDistributor.NotStakingContract.selector);
    vesting.claimFor(alice, 100 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Position loading
  // ═══════════════════════════════════════════════════════════════════════

  function test_loadPositions_setsAmountAndMask() public {
    _loadPosition(alice, SCHED0, 100 ether);

    IVestingDistributor.VestingPosition memory pos = vesting.getPosition(alice, SCHED0);
    assertEq(pos.totalAmount, 100 ether);
    assertEq(pos.claimedAmount, 0);
    assertEq(vesting.userScheduleMask(alice), 1); // bit 0 set
  }

  function test_loadPositions_additive() public {
    _loadPosition(alice, SCHED0, 60 ether);
    _loadPosition(alice, SCHED0, 40 ether);

    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 100 ether);
  }

  function test_loadPositions_multipleSched_setsBothBits() public {
    _loadPosition(alice, SCHED0, 50 ether);
    _loadPosition(alice, SCHED1, 50 ether);

    assertEq(vesting.userScheduleMask(alice), 3); // bits 0 and 1
  }

  function test_loadPositions_multipleUsers_independent() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _loadPosition(bob, SCHED0, 200 ether);

    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 100 ether);
    assertEq(vesting.getPosition(bob, SCHED0).totalAmount, 200 ether);
  }

  function test_loadPositions_revert_zeroAddress() public {
    vm.expectRevert(VestingDistributor.ZeroAddress.selector);
    vesting.loadPositions(_packPosition(address(0), SCHED0, 1 ether));
  }

  function test_loadPositions_revert_zeroAmount() public {
    vm.expectRevert(VestingDistributor.ZeroAmount.selector);
    vesting.loadPositions(_packPosition(alice, SCHED0, 0));
  }

  function test_loadPositions_acceptsUint96Max() public {
    _loadPosition(alice, SCHED0, type(uint96).max);

    IVestingDistributor.VestingPosition memory pos = vesting.getPosition(alice, SCHED0);
    assertEq(uint256(pos.totalAmount), type(uint96).max);
  }

  function test_loadPositions_revert_invalidScheduleType() public {
    vm.expectRevert(VestingDistributor.InvalidScheduleType.selector);
    vesting.loadPositions(_packPosition(alice, 5, 1 ether));
  }

  function test_loadPositions_packed_multipleEntriesPerAddress() public {
    // One beneficiary, both schedules in a single blob:
    // address(20) + count=2(1) + [sched(1) + amount(12)] × 2
    bytes memory data = abi.encodePacked(
      alice,
      uint8(2),
      SCHED0,
      uint96(60 ether),
      SCHED1,
      uint96(40 ether)
    );
    vesting.loadPositions(data);

    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 60 ether);
    assertEq(vesting.getPosition(alice, SCHED1).totalAmount, 40 ether);
    assertEq(vesting.userScheduleMask(alice), 3);
  }

  function test_loadPositions_packed_multipleAddresses() public {
    bytes memory data = abi.encodePacked(
      _packPosition(alice, SCHED0, 100 ether),
      _packPosition(bob, SCHED1, 200 ether)
    );
    vesting.loadPositions(data);

    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 100 ether);
    assertEq(vesting.getPosition(bob, SCHED1).totalAmount, 200 ether);
  }

  function test_loadPositions_revert_truncatedHeader() public {
    // 20 address bytes but no count byte
    vm.expectRevert(VestingDistributor.InvalidData.selector);
    vesting.loadPositions(abi.encodePacked(alice));
  }

  function test_loadPositions_revert_truncatedEntries() public {
    // count says 2 entries but only one is present
    bytes memory data = abi.encodePacked(alice, uint8(2), SCHED0, uint96(1 ether));
    vm.expectRevert(VestingDistributor.InvalidData.selector);
    vesting.loadPositions(data);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Vesting math
  // ═══════════════════════════════════════════════════════════════════════

  // SCHED0: cliff=2, vestingPeriods=10.
  // Timestamps: ts[0]=T+1M, ts[1]=T+2M, ts[2]=T+3M, …
  // _vestedFor checks: block.timestamp >= ts[cliffMonths=2] → ts[2] = T+3M.
  // Warping 3 months lands on exactly ts[2].

  function test_claimable_beforeCliff_isZero() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(2); // at ts[1] = T+2M, cliff is ts[2] = T+3M

    assertEq(vesting.claimableBalanceOf(alice), 0);
    assertEq(vesting.unclaimedBalanceOf(alice), 100 ether);
  }

  function test_claimable_atFirstMonth_isOneSlice() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(3); // lands on ts[2]: elapsed=1, vested=100e/10=10e

    assertEq(vesting.claimableBalanceOf(alice), 10 ether);
  }

  function test_claimable_progressesLinear() public {
    _loadPosition(alice, SCHED0, 100 ether);

    _warpPastMonth(5); // elapsed=3, vested=30e
    assertEq(vesting.claimableBalanceOf(alice), 30 ether);

    _warpPastMonth(2); // +2 more months → total 7M, elapsed=5, vested=50e
    assertEq(vesting.claimableBalanceOf(alice), 50 ether);
  }

  function test_claimable_fullyVested() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(12); // elapsed=10 == vestingPeriods → returns totalAmount directly

    assertEq(vesting.claimableBalanceOf(alice), 100 ether);
  }

  function test_claimable_pastFullVesting_staysAtTotal() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(20); // well past all 12 months

    assertEq(vesting.claimableBalanceOf(alice), 100 ether);
  }

  function test_claimable_usesNonLinearUnlockCurve() public {
    uint32[] memory curve = _nonLinearCurve();
    vesting.addScheduleWithUnlocks(2, "Non-linear", curve);

    _loadPosition(alice, 2, 100 ether);

    _warpPastMonth(3);
    assertEq(vesting.claimableBalanceOf(alice), 10 ether);

    _warpPastMonth(1);
    assertEq(vesting.claimableBalanceOf(alice), 40 ether);

    _warpPastMonth(8);
    assertEq(vesting.claimableBalanceOf(alice), 100 ether);
  }

  function test_setMonthTimestamps_updatesCalendarForExistingPositions() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(3);
    assertEq(vesting.claimableBalanceOf(alice), 10 ether);

    uint64[] memory shifted = new uint64[](TOTAL_MONTHS);
    for (uint256 i = 0; i < TOTAL_MONTHS; i++) {
      shifted[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }
    vesting.setMonthTimestamps(shifted);

    assertEq(vesting.claimableBalanceOf(alice), 0);
    assertEq(vesting.getPositionView(alice, SCHED0).nextReleaseAt, shifted[2]);
  }

  function test_claimFor_transfersTokens() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(3); // 10e claimable

    uint256 stakingBefore = token.balanceOf(address(staking));

    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, 10 ether);

    assertEq(claimed, 10 ether);
    assertEq(token.balanceOf(address(staking)), stakingBefore + 10 ether);
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 10 ether);
  }

  function test_claimFor_partialRequest_claimsOnlyRequested() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(6); // elapsed=4, vested=40e

    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, 15 ether); // request less than available

    assertEq(claimed, 15 ether);
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 15 ether);
    // remaining claimable = 40 - 15 = 25
    assertEq(vesting.claimableBalanceOf(alice), 25 ether);
  }

  function test_claimFor_accumulates_acrossMultipleCalls() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);

    _warpPastMonth(3); // elapsed=1, vested=10e
    vm.prank(address(staking));
    vesting.claimFor(alice, type(uint256).max); // claims 10e

    _warpPastMonth(3); // +3 more months → total 6M, elapsed=4, vested=40e, claimed=10e → claimable=30e
    vm.prank(address(staking));
    uint256 second = vesting.claimFor(alice, type(uint256).max);

    assertEq(second, 30 ether);
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 40 ether);
  }

  function test_claimFor_multipleSchedules_drainsBothInOrder() public {
    _loadPosition(alice, SCHED0, 100 ether); // cliff=2
    _loadPosition(alice, SCHED1, 80 ether);  // cliff=4
    _fundVesting(180 ether);
    _warpPastMonth(5); // sched0: elapsed=3→30e; sched1: elapsed=1→10e

    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, type(uint256).max);

    assertEq(claimed, 40 ether); // 30 + 10
  }

  function test_claimFor_partialRequest_crossesSchedulesInOrder() public {
    _loadPosition(alice, SCHED0, 100 ether); // 30e claimable at month 5
    _loadPosition(alice, SCHED1, 80 ether);  // 10e claimable at month 5
    _fundVesting(180 ether);
    _warpPastMonth(5);

    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, 35 ether);

    assertEq(claimed, 35 ether);
    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 30 ether);
    assertEq(vesting.getPosition(alice, SCHED1).claimedAmount, 5 ether);
    assertEq(vesting.claimableBalanceOf(alice), 5 ether);
  }

  function test_unclaimedBalance_decreasesOnClaim() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);

    assertEq(vesting.unclaimedBalanceOf(alice), 100 ether);

    _warpPastMonth(3);
    vm.prank(address(staking));
    vesting.claimFor(alice, type(uint256).max); // claims 10e

    assertEq(vesting.unclaimedBalanceOf(alice), 90 ether);
  }

  function test_withdrawToken_withdrawsStakingTokenLiabilities() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    address recipient = makeAddr("recipient");

    vesting.withdrawToken(address(token), recipient, 100 ether);

    assertEq(token.balanceOf(recipient), 100 ether);
    assertEq(token.balanceOf(address(vesting)), 0);
    assertEq(vesting.unclaimedBalanceOf(alice), 100 ether);
  }

  function test_withdrawToken_emitsEvent() public {
    _fundVesting(100 ether);
    address recipient = makeAddr("recipient");

    vm.expectEmit(true, true, false, true);
    emit VestingDistributor.TokenWithdrawn(address(token), recipient, 100 ether);
    vesting.withdrawToken(address(token), recipient, 100 ether);
  }

  function test_withdrawToken_canWithdrawArbitraryToken() public {
    MockERC20 other = new MockERC20("Other", "OTH");
    other.mint(address(vesting), 50 ether);
    address recipient = makeAddr("recipient");

    vesting.withdrawToken(address(other), recipient, 50 ether);

    assertEq(other.balanceOf(recipient), 50 ether);
    assertEq(other.balanceOf(address(vesting)), 0);
  }

  function test_withdrawToken_revert_zeroInputs() public {
    vm.expectRevert(VestingDistributor.ZeroAddress.selector);
    vesting.withdrawToken(address(0), alice, 1);

    vm.expectRevert(VestingDistributor.ZeroAddress.selector);
    vesting.withdrawToken(address(token), address(0), 1);

    vm.expectRevert(VestingDistributor.ZeroAmount.selector);
    vesting.withdrawToken(address(token), alice, 0);
  }

  function test_claimFor_maxUint_claimsOnlyClaimable() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(3); // only 10e claimable even though we request max

    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, type(uint256).max);

    assertEq(claimed, 10 ether); // not 100e
  }

  function test_claimFor_noPosition_returnsZero() public {
    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, 100 ether);
    assertEq(claimed, 0);
  }

  function test_claimFor_revert_underfundedVestingRollsBackClaimed() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(3);

    vm.prank(address(staking));
    vm.expectRevert();
    vesting.claimFor(alice, type(uint256).max);

    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 0);
    assertEq(vesting.claimableBalanceOf(alice), 10 ether);
  }

  function test_claimFor_revert_tokenTransferFailureRollsBackClaimed() public {
    RevertingERC20 badToken = new RevertingERC20();
    coordinator.setStakingToken(address(badToken));

    _loadPosition(alice, SCHED0, 100 ether);
    badToken.mint(address(vesting), 100 ether);
    _warpPastMonth(3);

    vm.prank(address(staking));
    vm.expectRevert(RevertingERC20.TransferFailed.selector);
    vesting.claimFor(alice, type(uint256).max);

    assertEq(vesting.getPosition(alice, SCHED0).claimedAmount, 0);
    assertEq(vesting.claimableBalanceOf(alice), 10 ether);
  }

  function test_getAllPositionViews_returnsCorrectFields() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(3);

    IVestingDistributor.VestingPositionView[] memory views = vesting.getAllPositionViews(alice);
    assertEq(views.length, 1);

    IVestingDistributor.VestingPositionView memory v = views[0];
    assertEq(v.scheduleType, SCHED0);
    assertEq(v.cliffMonths, 2);
    assertEq(v.vestingPeriods, 10);
    assertEq(v.totalAmount, 100 ether);
    assertEq(v.vestedAmount, 10 ether);
    assertEq(v.claimableAmount, 10 ether);
    assertEq(v.lockedAmount, 90 ether);
    assertEq(v.claimedAmount, 0);
    // nextReleaseAt should be ts[3] = T + 4*MONTH (next unlock after ts[2])
    assertEq(v.nextReleaseAt, block.timestamp + MONTH);
  }

  function test_getAllPositionViews_emptyForNoPositions() public view {
    IVestingDistributor.VestingPositionView[] memory views = vesting.getAllPositionViews(alice);
    assertEq(views.length, 0);
  }

  function test_claimFor_nonLinearCurve_transfersCorrectly() public {
    uint32[] memory curve = _nonLinearCurve();
    vesting.addScheduleWithUnlocks(2, "Non-linear", curve);
    _loadPosition(alice, 2, 100 ether);
    _fundVesting(100 ether);

    _warpPastMonth(3); // elapsed=3, cumulative=100_000 → 10e vested
    vm.prank(address(staking));
    assertEq(vesting.claimFor(alice, type(uint256).max), 10 ether);

    _warpPastMonth(1); // elapsed=4, cumulative=400_000 → 40e vested, 10e claimed → 30e claimable
    vm.prank(address(staking));
    assertEq(vesting.claimFor(alice, type(uint256).max), 30 ether);
    assertEq(vesting.getPosition(alice, 2).claimedAmount, 40 ether);
  }

  function test_nextReleaseAt_nonLinearCurve_skipsGaps() public {
    uint32[] memory curve = _nonLinearCurve();
    // curve: month 2 = 10%, month 3 = 30%, months 4-10 = 0% (gap), month 11 = 60%
    vesting.addScheduleWithUnlocks(2, "Non-linear", curve);
    _loadPosition(alice, 2, 100 ether);

    _warpPastMonth(4); // elapsed=4, currently at cumulative[3]=400_000
    // next non-zero delta is at index 11 → monthTimestamps[11] = T + 12*MONTH = block.timestamp + 8*MONTH
    IVestingDistributor.VestingPositionView memory v = vesting.getPositionView(alice, 2);
    assertEq(v.nextReleaseAt, block.timestamp + 8 * uint256(MONTH));
  }

  function test_nextReleaseAt_isZeroWhenFullyVested() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(12); // fully vested

    IVestingDistributor.VestingPositionView memory v = vesting.getPositionView(alice, SCHED0);
    assertEq(v.nextReleaseAt, 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Pause
  // ═══════════════════════════════════════════════════════════════════════

  function test_pause_blocksClaimFor() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(3);

    vesting.pause();

    vm.prank(address(staking));
    vm.expectRevert("Pausable: paused");
    vesting.claimFor(alice, 10 ether);
  }

  function test_pause_blocksLoadPositions() public {
    vesting.pause();

    vm.expectRevert("Pausable: paused");
    vesting.loadPositions(_packPosition(alice, SCHED0, 1 ether));
  }

  function test_unpause_restoresBothOperations() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    vesting.pause();
    vesting.unpause();

    // load should work
    _loadPosition(alice, SCHED0, 10 ether);
    assertEq(vesting.getPosition(alice, SCHED0).totalAmount, 110 ether);

    // claimFor should work
    _warpPastMonth(3);
    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(alice, type(uint256).max);
    assertGt(claimed, 0);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Events
  // ═══════════════════════════════════════════════════════════════════════

  function test_loadPositions_emitsEvent() public {
    vm.expectEmit(true, true, false, true);
    emit VestingDistributor.VestingPositionLoaded(alice, SCHED0, 50 ether);
    vesting.loadPositions(_packPosition(alice, SCHED0, 50 ether));
  }

  function test_claimFor_emitsVestingClaimed() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(3);

    vm.expectEmit(true, true, true, false);
    emit VestingDistributor.VestingClaimed(alice, address(staking), SCHED0, 10 ether);
    vm.prank(address(staking));
    vesting.claimFor(alice, type(uint256).max);
  }

  function _nonLinearCurve() private pure returns (uint32[] memory curve) {
    curve = new uint32[](TOTAL_MONTHS);
    curve[2] = 100_000;
    curve[3] = 300_000;
    curve[11] = 600_000;
  }
}
