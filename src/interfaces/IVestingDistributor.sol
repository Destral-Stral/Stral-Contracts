// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";

/// @title IVestingDistributor
/// @notice Interface for vesting allocation reads and staking-routed claims.
interface IVestingDistributor {
  /// @notice A vesting schedule defined by a cliff length; all schedules share the global month timestamps.
  struct VestingSchedule {
    /// @notice Whether new positions can be loaded into this schedule.
    bool active;
    /// @notice Number of full vesting months before the first positive unlock.
    uint8 cliffMonths;
    /// @notice Human-readable schedule label for UI display.
    string label;
    /// @notice Cumulative unlock percentages in parts-per-million, aligned with month timestamps.
    uint32[] cumulativeUnlockPpm;
  }

  /// @notice Packed storage for a user's consolidated position in one schedule type.
  struct VestingPosition {
    /// @notice Total token allocation loaded for the position.
    uint128 totalAmount;
    /// @notice Token amount already claimed from the position.
    uint128 claimedAmount;
  }

  /// @notice Computed view of a user's position in one schedule type, returned by read functions.
  struct VestingPositionView {
    /// @notice Schedule index for this position.
    uint8 scheduleType;
    /// @notice Number of full vesting months before the first positive unlock.
    uint8 cliffMonths;
    /// @notice Total number of vesting periods after the cliff.
    uint256 vestingPeriods;
    /// @notice Human-readable schedule label for UI display.
    string label;
    /// @notice Total token allocation loaded for the position.
    uint256 totalAmount;
    /// @notice Token amount already claimed from the position.
    uint256 claimedAmount;
    /// @notice Token amount vested as of the current timestamp.
    uint256 vestedAmount;
    /// @notice Token amount currently claimable.
    uint256 claimableAmount;
    /// @notice Token amount not yet vested.
    uint256 lockedAmount;
    /// @dev Timestamp of the next vesting event; 0 if fully vested.
    uint64 nextReleaseAt;
  }

  /// @notice Returns the platform token used for all vesting transfers.
  /// @return The ERC-20 token used by the vesting distributor.
  function token() external view returns (IERC20);

  /// @notice Returns one timestamp from the shared vesting calendar.
  /// @param index Calendar index to read.
  /// @return Month-end unix timestamp.
  function monthTimestamps(
    uint256 index
  ) external view returns (uint64);

  /// @notice Returns the schedule definition for a given type.
  /// @param scheduleType Schedule index to read.
  /// @return Schedule definition.
  function getSchedule(
    uint8 scheduleType
  ) external view returns (VestingSchedule memory);

  /// @notice Returns the raw packed position for a (user, scheduleType) pair.
  /// @param user         Beneficiary address.
  /// @param scheduleType Schedule index to read.
  /// @return Packed vesting position.
  function getPosition(
    address user,
    uint8 scheduleType
  ) external view returns (VestingPosition memory);

  /// @notice Returns the computed position view for a (user, scheduleType) pair.
  /// @param user         Beneficiary address.
  /// @param scheduleType Schedule index to read.
  /// @return Computed vesting position view.
  function getPositionView(
    address user,
    uint8 scheduleType
  ) external view returns (VestingPositionView memory);

  /// @notice Returns computed views for all schedule types in which the user has a position.
  /// @param user Beneficiary address.
  /// @return Computed vesting position views.
  function getAllPositionViews(
    address user
  ) external view returns (VestingPositionView[] memory);

  /// @notice Returns the bitmask of schedule types in which a user has positions.
  /// @param user Beneficiary address.
  /// @return Bitmask of schedule indexes.
  function userScheduleMask(
    address user
  ) external view returns (uint8);

  /// @notice Returns the total tokens remaining across all of a user's positions.
  /// @param user Beneficiary address.
  /// @return Remaining unclaimed amount in wei.
  function unclaimedBalanceOf(
    address user
  ) external view returns (uint256);

  /// @notice Returns the total amount immediately claimable across all of a user's positions.
  /// @param user Beneficiary address.
  /// @return Immediately claimable amount in wei.
  function claimableBalanceOf(
    address user
  ) external view returns (uint256);

  /// @notice Claims up to `amount` tokens for a user.
  /// @param user   Beneficiary whose positions are drawn.
  /// @param amount Maximum token amount to claim in wei.
  /// @return claimed Actual amount claimed in wei.
  function claimFor(
    address user,
    uint256 amount
  ) external returns (uint256 claimed);
}
