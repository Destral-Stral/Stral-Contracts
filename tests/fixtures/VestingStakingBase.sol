// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseTest } from "fixtures/BaseTest.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { Staking } from "src/staking/Staking.sol";

/// @dev Shared fixture for vesting + staking unit and invariant tests.
///      Sets up: coordinator (from BaseTest) with stakingToken wired to the
///      MockERC20, a VestingDistributor, a Staking contract, 12 month-end
///      timestamps, and two schedules:
///        SCHED0 (scheduleType=0): cliff=2, vestingPeriods=10
///        SCHED1 (scheduleType=1): cliff=4, vestingPeriods=8
///
///      Time helpers use _warpPastMonth(n) which advances block.timestamp by
///      n * MONTH, landing exactly on monthTimestamps[n-1] (>= comparison in
///      _vestedFor passes at that boundary).
abstract contract VestingStakingBase is BaseTest {
  VestingDistributor vesting;
  Staking staking;

  uint64 constant MONTH = 30 days;
  uint256 constant TOTAL_MONTHS = 12;
  uint8 constant SCHED0 = 0; // cliff=2, vestingPeriods=10
  uint8 constant SCHED1 = 1; // cliff=4, vestingPeriods=8
  uint64 constant LOCK = 7 days;

  address alice = makeAddr("vsAlice");
  address bob = makeAddr("vsBob");

  function setUp() public virtual override {
    super.setUp();

    coordinator.setStakingToken(address(token));

    uint64[] memory ts = new uint64[](TOTAL_MONTHS);
    for (uint256 i = 0; i < TOTAL_MONTHS; i++) {
      ts[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }

    VestingDistributor.ScheduleInput[] memory schedules = new VestingDistributor.ScheduleInput[](2);
    schedules[0] = _linearSchedule(2, "Cliff-2"); // SCHED0
    schedules[1] = _linearSchedule(4, "Cliff-4"); // SCHED1

    vesting = VestingDistributor(
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

    staking = Staking(
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

    // Both contracts resolve each other through the coordinator registry.
    coordinator.setVestingContract(address(vesting));
    coordinator.setStakingContract(address(staking));
  }

  /// @dev Pack a single-entry loadPositions payload:
  ///      address(20) + count(1) + scheduleType(1) + uint96 amount(12).
  function _packPosition(
    address user,
    uint8 schedType,
    uint96 amount
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(user, uint8(1), schedType, amount);
  }

  /// @dev Load a single vesting position for a user.
  function _loadPosition(address user, uint8 schedType, uint96 amount) internal {
    vesting.loadPositions(_packPosition(user, schedType, amount));
  }

  /// @dev Mint tokens into the vesting contract so claims can be paid out.
  function _fundVesting(uint256 amount) internal {
    token.mint(address(vesting), amount);
  }

  /// @dev Warp forward by n months relative to current block.timestamp.
  ///      Landing on monthTimestamps[n-1] satisfies the >= boundary check.
  function _warpPastMonth(uint256 n) internal {
    vm.warp(block.timestamp + n * uint256(MONTH));
  }

  /// @dev Approve and deposit tokens into the staking contract for a user.
  function _deposit(address user, uint256 amount) internal {
    token.mint(user, amount);
    vm.startPrank(user);
    token.approve(address(staking), amount);
    staking.deposit(amount);
    vm.stopPrank();
  }

  function _linearSchedule(
    uint8 cliffMonths,
    string memory label
  ) internal pure returns (VestingDistributor.ScheduleInput memory schedule) {
    uint256 vestingPeriods = TOTAL_MONTHS - cliffMonths;
    uint32 perPeriod = uint32(1_000_000 / vestingPeriods);
    uint32[] memory unlocks = new uint32[](TOTAL_MONTHS);
    for (uint256 i = cliffMonths; i < TOTAL_MONTHS - 1; i++) {
      unlocks[i] = perPeriod;
    }
    unlocks[TOTAL_MONTHS - 1] = uint32(1_000_000 - perPeriod * (vestingPeriods - 1));

    schedule = VestingDistributor.ScheduleInput({
      cliffMonths: cliffMonths,
      label: label,
      monthlyUnlockPpm: unlocks
    });
  }
}
