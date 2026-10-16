// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { VestingStakingBase } from "fixtures/VestingStakingBase.sol";
import { Staking } from "src/staking/Staking.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { FalseReturnERC20 } from "fixtures/AdversarialTokens.sol";

contract StakingTest is VestingStakingBase {

  // ═══════════════════════════════════════════════════════════════════════
  //  Admin
  // ═══════════════════════════════════════════════════════════════════════

  function test_setLockDuration_updatesAndEmits() public {
    vm.expectEmit(false, false, false, true);
    emit Staking.StakingLockDurationUpdated(LOCK, 14 days);
    staking.setLockDuration(14 days);
    assertEq(staking.lockDuration(), 14 days);
  }

  function test_vesting_resolvesFromCoordinator() public {
    address newVesting = makeAddr("newVesting");
    coordinator.setVestingContract(newVesting);
    assertEq(address(staking.vesting()), newVesting);
  }

  function test_adminFunctions_revert_nonOwner() public {
    address rando = makeAddr("rando");
    vm.startPrank(rando);

    vm.expectRevert(Staking.NotCoordinatorOwner.selector);
    staking.setLockDuration(1 days);

    vm.expectRevert(Staking.NotCoordinatorOwner.selector);
    staking.withdrawToken(address(token), rando, 1);

    vm.expectRevert(Staking.NotCoordinatorOwner.selector);
    staking.pause();

    vm.stopPrank();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Deposit
  // ═══════════════════════════════════════════════════════════════════════

  function test_deposit_createsPosition() public {
    _deposit(alice, 100 ether);

    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.stakingLocked, 100 ether);
    assertEq(s.stakingWithdrawable, 0);
    assertEq(staking.nextPositionId(), 1);
  }

  function test_deposit_emitsEvent() public {
    token.mint(alice, 50 ether);
    vm.startPrank(alice);
    token.approve(address(staking), 50 ether);

    vm.expectEmit(false, true, false, true); // check user and amount, skip positionId
    emit Staking.StakingPositionCreated(bytes32(0), alice, 50 ether, uint64(block.timestamp) + LOCK);
    staking.deposit(50 ether);
    vm.stopPrank();
  }

  function test_deposit_revert_zeroAmount() public {
    vm.prank(alice);
    vm.expectRevert(Staking.ZeroAmount.selector);
    staking.deposit(0);
  }

  function test_deposit_revert_tokenTransferFailureDoesNotCreatePosition() public {
    FalseReturnERC20 badToken = new FalseReturnERC20();
    coordinator.setStakingToken(address(badToken));
    badToken.mint(alice, 100 ether);

    vm.startPrank(alice);
    badToken.approve(address(staking), 100 ether);
    vm.expectRevert();
    staking.deposit(100 ether);
    vm.stopPrank();

    assertEq(staking.nextPositionId(), 0);
    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions.length, 0);
  }

  function test_stake_alias_sameAsDeposit() public {
    token.mint(alice, 100 ether);
    vm.startPrank(alice);
    token.approve(address(staking), 100 ether);
    staking.stake(100 ether);
    vm.stopPrank();

    assertEq(staking.nextPositionId(), 1);
  }

  function test_deposit_multiplePositions_uniqueIds() public {
    _deposit(alice, 50 ether);
    _deposit(alice, 75 ether);

    assertEq(staking.nextPositionId(), 2);
    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions.length, 2);
    assertTrue(d.stakingPositions[0].positionId != d.stakingPositions[1].positionId);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Lock duration enforcement
  // ═══════════════════════════════════════════════════════════════════════

  function test_lockDuration_enforcedOnNewDeposit() public {
    _deposit(alice, 100 ether);

    // Before lock expires: nothing withdrawable, NothingUnlockable
    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(100 ether);

    // After lock expires: withdrawable
    vm.warp(block.timestamp + uint256(LOCK) + 1);
    vm.prank(alice);
    staking.unlock(100 ether);
    assertEq(token.balanceOf(alice), 100 ether);
  }

  function test_withdrawToken_withdrawsDirectStakingLiabilities() public {
    _deposit(alice, 100 ether);
    address recipient = makeAddr("recipient");

    staking.withdrawToken(address(token), recipient, 100 ether);

    assertEq(token.balanceOf(recipient), 100 ether);
    assertEq(token.balanceOf(address(staking)), 0);
    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.totalVipStake, 100 ether);
  }

  function test_withdrawToken_revert_zeroInputs() public {
    vm.expectRevert(Staking.ZeroAddress.selector);
    staking.withdrawToken(address(0), alice, 1);

    vm.expectRevert(Staking.ZeroAddress.selector);
    staking.withdrawToken(address(token), address(0), 1);

    vm.expectRevert(Staking.ZeroAmount.selector);
    staking.withdrawToken(address(token), alice, 0);
  }

  function test_lockDuration_changeDoesNotAffectExistingPositions() public {
    _deposit(alice, 100 ether); // deposited with LOCK=7days

    // Admin increases lock duration; existing position should still unlock at original time
    staking.setLockDuration(30 days);

    vm.warp(block.timestamp + uint256(LOCK) + 1); // past original lock only
    vm.prank(alice);
    staking.unlock(100 ether); // should succeed (original unlockAt honored)
    assertEq(token.balanceOf(alice), 100 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Unlock — withdrawal priority
  // ═══════════════════════════════════════════════════════════════════════

  function test_unlock_fromVestingFirst_beforeStaking() public {
    // Alice has vesting claimable + unlocked staking
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _deposit(alice, 50 ether);

    // Warp past cliff (3M) and past lock (7d) simultaneously
    vm.warp(block.timestamp + 3 * uint256(MONTH));
    // Now: vesting claimable=10e, staking withdrawable=50e

    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(25 ether); // should pull all 25 from vesting first

    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(token.balanceOf(alice) - aliceBefore, 25 ether);
    // Vesting claimable was 10e, so only 10 from vesting, 15 from staking
    assertEq(s.vestingUnclaimed, 90 ether); // 100 - 10 claimed
    // staking withdrawable reduced by 15
    assertEq(s.stakingWithdrawable, 35 ether);
  }

  function test_unlock_emitsTokensUnlocked() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    vm.expectEmit(true, true, false, true);
    emit Staking.TokensUnlocked(alice, alice, 50 ether, 0, 50 ether);
    vm.prank(alice);
    staking.unlock(50 ether);
  }

  function test_unlock_onlyVesting_noDirectStake() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _warpPastMonth(12); // fully vested

    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    uint256 unlocked = staking.unlock(50 ether);

    assertEq(unlocked, 50 ether);
    assertEq(token.balanceOf(alice) - aliceBefore, 50 ether);
  }

  function test_unlock_onlyDirectStake_noVesting() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    uint256 aliceBefore = token.balanceOf(alice);
    vm.prank(alice);
    staking.unlock(60 ether);

    assertEq(token.balanceOf(alice) - aliceBefore, 60 ether);
  }

  function test_unlock_partial_leavesRemainder() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    vm.prank(alice);
    staking.unlock(40 ether);

    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.stakingWithdrawable, 60 ether);
    assertEq(s.stakingWithdrawn, 40 ether);
  }

  function test_unlock_revert_zeroAmount() public {
    vm.prank(alice);
    vm.expectRevert(Staking.ZeroAmount.selector);
    staking.unlock(0);
  }

  function test_unlock_revert_nothingUnlockable_noDeposit() public {
    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(100 ether);
  }

  function test_unlock_revert_nothingUnlockable_allLocked() public {
    _deposit(alice, 100 ether);
    // Lock not expired, no vesting

    vm.prank(alice);
    vm.expectRevert(Staking.NothingUnlockable.selector);
    staking.unlock(100 ether);
  }

  function test_unlock_revert_underfundedStakingRollsBackWithdrawn() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    deal(address(token), address(staking), 0);

    vm.prank(alice);
    vm.expectRevert();
    staking.unlock(100 ether);

    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.stakingPositions[0].withdrawnAmount, 0);
    assertEq(d.summary.stakingWithdrawable, 100 ether);
  }

  function test_unstake_alias() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    vm.prank(alice);
    staking.unstake(100 ether);
    assertEq(token.balanceOf(alice), 100 ether);
  }

  function test_unlock_multiplePositions_drainsInOrder() public {
    _deposit(alice, 40 ether); // pos0
    _deposit(alice, 60 ether); // pos1
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    vm.prank(alice);
    staking.unlock(50 ether);

    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    // pos0 fully drained (40e), pos1 partially drained (10e)
    assertEq(d.stakingPositions[0].withdrawnAmount, 40 ether);
    assertEq(d.stakingPositions[1].withdrawnAmount, 10 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Pause
  // ═══════════════════════════════════════════════════════════════════════

  function test_pause_blocksDeposit() public {
    staking.pause();

    token.mint(alice, 100 ether);
    vm.startPrank(alice);
    token.approve(address(staking), 100 ether);
    vm.expectRevert("Pausable: paused");
    staking.deposit(100 ether);
    vm.stopPrank();
  }

  function test_pause_blocksUnlock() public {
    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);

    staking.pause();

    vm.prank(alice);
    vm.expectRevert("Pausable: paused");
    staking.unlock(100 ether);
  }

  function test_unpause_restoresOperations() public {
    staking.pause();
    staking.unpause();

    _deposit(alice, 100 ether);
    vm.warp(block.timestamp + uint256(LOCK) + 1);
    vm.prank(alice);
    staking.unlock(100 ether);
    assertEq(token.balanceOf(alice), 100 ether);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Read views
  // ═══════════════════════════════════════════════════════════════════════

  function test_totalStakedBalanceOf_sumVestingAndDirect() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _deposit(alice, 50 ether);

    // unclaimedBalanceOf = 100e (totalAmount - claimedAmount)
    // directStaked = 50e
    assertEq(staking.totalStakedBalanceOf(alice), 150 ether);
  }

  function test_totalStakedBalanceOf_decreasesOnWithdrawal() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _fundVesting(100 ether);
    _deposit(alice, 50 ether);
    _warpPastMonth(12); // all vesting claimable, staking still locked

    uint256 before = staking.totalStakedBalanceOf(alice);
    assertEq(before, 150 ether);

    vm.prank(alice);
    staking.unlock(30 ether); // from vesting

    // unclaimed drops from 100 to 70
    assertEq(staking.totalStakedBalanceOf(alice), 120 ether);
  }

  function test_getUserStakeSummary_allFields() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _warpPastMonth(3); // vested=10e (elapsed=1)
    // Deposit AFTER the warp so the 7-day lock has not yet expired
    _deposit(alice, 80 ether); // unlockAt = (now) + 7d, still locked

    Staking.UserStakeSummary memory s = staking.getUserStakeSummary(alice);
    assertEq(s.vestingUnclaimed, 100 ether);
    assertEq(s.vestingClaimable, 10 ether);
    assertEq(s.stakingLocked, 80 ether);
    assertEq(s.stakingWithdrawable, 0);
    assertEq(s.stakingWithdrawn, 0);
    assertEq(s.totalVipStake, 180 ether); // 100 + 80 + 0
  }

  function test_getUserStakeDetails_returnsAllPositions() public {
    _loadPosition(alice, SCHED0, 100 ether);
    _loadPosition(alice, SCHED1, 50 ether);
    _deposit(alice, 30 ether);
    _deposit(alice, 40 ether);

    Staking.UserStakeDetails memory d = staking.getUserStakeDetails(alice);
    assertEq(d.vestingPositions.length, 2);
    assertEq(d.stakingPositions.length, 2);
  }

  function test_getUserStakeDetailsPage_windowing() public {
    for (uint256 i = 0; i < 5; i++) {
      _deposit(alice, 10 ether);
    }

    Staking.UserStakeDetailsPage memory page = staking.getUserStakeDetailsPage(alice, 1, 2);
    assertEq(page.stakingPositionCount, 5);
    assertEq(page.stakingPositions.length, 2);
    // positions[0] should be the second position (offset=1)
    Staking.UserStakeDetails memory full = staking.getUserStakeDetails(alice);
    assertEq(page.stakingPositions[0].positionId, full.stakingPositions[1].positionId);
  }

  function test_getUserStakeDetailsPage_offsetPastEnd_returnsEmpty() public {
    _deposit(alice, 10 ether);

    Staking.UserStakeDetailsPage memory page = staking.getUserStakeDetailsPage(alice, 5, 10);
    assertEq(page.stakingPositions.length, 0);
    assertEq(page.stakingPositionCount, 1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  Position ID uniqueness
  // ═══════════════════════════════════════════════════════════════════════

  function test_positionIds_unique_acrossUsers() public {
    _deposit(alice, 10 ether);
    _deposit(bob, 10 ether);

    Staking.UserStakeDetails memory da = staking.getUserStakeDetails(alice);
    Staking.UserStakeDetails memory db = staking.getUserStakeDetails(bob);
    assertTrue(da.stakingPositions[0].positionId != db.stakingPositions[0].positionId);
  }
}
