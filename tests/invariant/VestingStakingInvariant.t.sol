// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts-5/proxy/ERC1967/ERC1967Proxy.sol";
import { VestingDistributor } from "src/staking/VestingDistributor.sol";
import { Staking } from "src/staking/Staking.sol";
import { SmartWalletCoordinator } from "src/smartWallet/SmartWalletCoordinator.sol";
import { MockERC20 } from "fixtures/MockERC20.sol";
import { IVestingDistributor } from "src/interfaces/IVestingDistributor.sol";

/// @dev Drives vesting + staking with bounded random inputs.
///      Ghost variables track token movement for conservation checks.
contract VestingStakingHandler is Test {
  VestingDistributor public vesting;
  Staking public staking;
  MockERC20 public token;
  SmartWalletCoordinator public coordinator;

  address[4] public users;
  uint256 public ghostTotalLoaded;
  uint256 public ghostTotalClaimed;
  uint256 public ghostTotalDeposited;
  uint256 public ghostTotalUnlocked;
  uint256 public ghostDepositCount;

  uint256 constant TOTAL_MONTHS = 8;
  uint64 constant MONTH = 30 days;
  uint8 constant NUM_SCHEDULES = 2;

  constructor() {
    address[] memory empty = new address[](0);
    coordinator = SmartWalletCoordinator(
      address(
        new ERC1967Proxy(
          address(new SmartWalletCoordinator()),
          abi.encodeCall(
            SmartWalletCoordinator.initialize,
            (
              SmartWalletCoordinator.Setup({
                owner: address(0),
                strategyAddress: address(0),
                withdrawalDelay: 0,
                allowedTokens: empty,
                stakingToken: address(0),
                stakingContract: address(0),
                vestingContract: address(0),
                relayer: address(0)
              })
            )
          )
        )
      )
    );

    token = new MockERC20("T", "T");
    coordinator.setStakingToken(address(token));

    uint64[] memory ts = new uint64[](TOTAL_MONTHS);
    for (uint256 i = 0; i < TOTAL_MONTHS; i++) {
      ts[i] = uint64(block.timestamp + (i + 1) * MONTH);
    }

    VestingDistributor.ScheduleInput[] memory schedules = new VestingDistributor.ScheduleInput[](2);
    schedules[0] = _linearSchedule(1, "C1"); // cliff=1, vestingPeriods=7
    schedules[1] = _linearSchedule(2, "C2"); // cliff=2, vestingPeriods=6

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
            (address(coordinator), 7 days)
          )
        )
      )
    );
    coordinator.setVestingContract(address(vesting));
    coordinator.setStakingContract(address(staking));

    users[0] = makeAddr("inv_u0");
    users[1] = makeAddr("inv_u1");
    users[2] = makeAddr("inv_u2");
    users[3] = makeAddr("inv_u3");
  }

  function loadPosition(uint256 userSeed, uint256 schedSeed, uint256 amount) external {
    amount = bound(amount, 1, 1_000_000 ether);
    address user = users[userSeed % 4];
    uint8 sched = uint8(schedSeed % NUM_SCHEDULES);

    vesting.loadPositions(abi.encodePacked(user, uint8(1), sched, uint96(amount)));
    token.mint(address(vesting), amount);
    ghostTotalLoaded += amount;
  }

  function claimAll(uint256 userSeed) external {
    address user = users[userSeed % 4];
    vm.prank(address(staking));
    uint256 claimed = vesting.claimFor(user, type(uint256).max);
    ghostTotalClaimed += claimed;
  }

  function deposit(uint256 userSeed, uint256 amount) external {
    amount = bound(amount, 1, 10_000 ether);
    address user = users[userSeed % 4];
    token.mint(user, amount);
    vm.startPrank(user);
    token.approve(address(staking), amount);
    staking.deposit(amount);
    vm.stopPrank();

    ghostTotalDeposited += amount;
    ghostDepositCount++;
  }

  function unlock(uint256 userSeed, uint256 amount) external {
    amount = bound(amount, 1, 10_000 ether);
    address user = users[userSeed % 4];
    uint256 vestingBalanceBefore = token.balanceOf(address(vesting));
    vm.prank(user);
    try staking.unlock(amount) returns (uint256 unlocked) {
      uint256 vestingClaimed = vestingBalanceBefore - token.balanceOf(address(vesting));
      ghostTotalClaimed += vestingClaimed;
      ghostTotalUnlocked += unlocked;
    } catch { }
  }

  function warpTime(uint256 seconds_) external {
    seconds_ = bound(seconds_, 1, 60 days);
    vm.warp(block.timestamp + seconds_);
  }

  function _linearSchedule(
    uint8 cliffMonths,
    string memory label
  ) private pure returns (VestingDistributor.ScheduleInput memory schedule) {
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

contract VestingStakingInvariantTest is StdInvariant, Test {
  VestingStakingHandler handler;

  function setUp() public {
    handler = new VestingStakingHandler();
    targetContract(address(handler));
  }

  /// @dev Tokens loaded into vesting = tokens still in vesting + tokens claimed (sent to handler/staking).
  ///      Staking may also hold direct deposits; vesting balance tracks only vesting payouts.
  function invariant_vestingTokenConservation() public view {
    uint256 vestingBalance = handler.token().balanceOf(address(handler.vesting()));
    assertEq(
      vestingBalance + handler.ghostTotalClaimed(),
      handler.ghostTotalLoaded(),
      "token conservation violated"
    );
  }

  /// @dev Sum of unclaimed balances across all tracked users must not exceed vesting token balance.
  function invariant_vestingBalanceCoversTotalUnclaimed() public view {
    uint256 totalUnclaimed;
    for (uint256 i = 0; i < 4; i++) {
      totalUnclaimed += handler.vesting().unclaimedBalanceOf(handler.users(i));
    }
    assertGe(
      handler.token().balanceOf(address(handler.vesting())),
      totalUnclaimed,
      "vesting underfunded"
    );
  }

  /// @dev For every (user, schedule) pair: claimedAmount must never exceed totalAmount.
  function invariant_claimedNeverExceedsTotal() public view {
    for (uint256 i = 0; i < 4; i++) {
      for (uint8 s = 0; s < 2; s++) {
        IVestingDistributor.VestingPosition memory pos =
          handler.vesting().getPosition(handler.users(i), s);
        assertLe(pos.claimedAmount, pos.totalAmount, "claimed > total");
      }
    }
  }

  /// @dev If a user has a bit set in userScheduleMask, their totalAmount for that schedule must be > 0.
  function invariant_bitmaskConsistency() public view {
    for (uint256 i = 0; i < 4; i++) {
      address user = handler.users(i);
      uint8 mask = handler.vesting().userScheduleMask(user);
      for (uint8 s = 0; s < 2; s++) {
        if (mask & (uint8(1) << s) != 0) {
          IVestingDistributor.VestingPosition memory pos =
            handler.vesting().getPosition(user, s);
          assertGt(pos.totalAmount, 0, "mask set but totalAmount is zero");
        }
      }
    }
  }

  /// @dev nextPositionId must be monotonically non-decreasing (it only ever increments).
  function invariant_positionIdMonotonicallyIncreases() public view {
    assertEq(handler.staking().nextPositionId(), handler.ghostDepositCount());
  }

  /// @dev Staking balance equals deposits plus vesting claims that reached staking, minus user unlocks.
  function invariant_stakingTokenConservation() public view {
    uint256 stakingBalance = handler.token().balanceOf(address(handler.staking()));
    assertEq(
      stakingBalance + handler.ghostTotalUnlocked(),
      handler.ghostTotalDeposited() + handler.ghostTotalClaimed(),
      "staking token conservation violated"
    );
  }

  /// @dev withdrawnAmount must never exceed position amount for any position.
  function invariant_withdrawnNeverExceedsPositionAmount() public view {
    for (uint256 i = 0; i < 4; i++) {
      address user = handler.users(i);
      Staking.UserStakeDetails memory d = handler.staking().getUserStakeDetails(user);
      for (uint256 j = 0; j < d.stakingPositions.length; j++) {
        Staking.StakingPosition memory pos = d.stakingPositions[j];
        assertLe(pos.withdrawnAmount, pos.amount, "withdrawnAmount > amount");
      }
    }
  }
}
