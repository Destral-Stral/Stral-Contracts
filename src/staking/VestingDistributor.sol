// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Contracts
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
// Libs
import { SafeERC20 } from "@openzeppelin/contracts-5/token/ERC20/utils/SafeERC20.sol";
// Interfaces
import { IERC20 } from "@openzeppelin/contracts-5/token/ERC20/IERC20.sol";
import { ISmartWalletCoordinator } from "src/interfaces/ISmartWalletCoordinator.sol";
import { IVestingDistributor } from "src/interfaces/IVestingDistributor.sol";

/// @title VestingDistributor
/// @notice Holds preloaded vesting allocations and releases tokens to beneficiaries according to
///         month-based schedules. Schedules share a single uploaded array of 40 month-end
///         timestamps and can use either linear or explicit monthly unlock curves. Multiple
///         off-chain lots for the same (user, schedule) are consolidated into one on-chain position.
///         All claims are routed through the Staking contract.
/// @dev Deployed as a transparent proxy. Admin identity is read from
///      `SmartWalletCoordinator.owner()` at call time; there is no local owner storage.
///      `loadPositions` additionally accepts a `loader` account, set to the proxy deployer
///      at initialization and rotatable via `setLoader`, so position loads do not depend
///      on where the coordinator ownership sits.
///      Supports up to 8 schedule types (one bit per type in the per-user uint8 bitmask).
contract VestingDistributor is
  IVestingDistributor,
  Initializable,
  PausableUpgradeable
{
  using SafeERC20 for IERC20;

  uint256 public constant UNLOCK_PPM_DENOMINATOR = 1_000_000;

  // ====== STORAGE ====== //

  /// @notice The coordinator contract from which admin identity, the staking token and
  ///         the staking contract permitted to call `claimFor` are read.
  ISmartWalletCoordinator public coordinator;

  /// @notice Uploaded month-end timestamps shared by all schedules.
  ///         monthTimestamps[0] = end of month 1, monthTimestamps[39] = end of month 40.
  uint64[] public monthTimestamps;

  /// @notice Registered vesting schedules (max 8 to fit in the per-user uint8 bitmask).
  VestingSchedule[] private _schedules;

  /// @notice Packed (totalAmount, claimedAmount) per user per schedule type.
  ///         Multiple loads for the same pair are additive.
  mapping(address => mapping(uint8 => VestingPosition))
    private _positions;

  /// @notice Bitmask indicating which schedule types a user has a non-zero position in.
  mapping(address => uint8) public userScheduleMask;

  /// @notice Temporary account allowed to call `loadPositions` alongside the coordinator
  ///         owner. Set to the proxy deployer at initialization so positions can be loaded
  ///         while the coordinator sits with the multisig; reassign or revoke via `setLoader`.
  address public loader;

  // ====== INPUT STRUCTS ====== //

  /// @notice Input shape for a schedule configured at proxy initialization.
  struct ScheduleInput {
    /// @notice Number of full vesting months before the first positive unlock.
    uint8 cliffMonths;
    /// @notice Human-readable schedule label for UI display.
    string label;
    /// @notice Per-month unlock weights in parts-per-million, aligned with `monthTimestamps`.
    uint32[] monthlyUnlockPpm;
  }

  // ====== ERRORS ====== //

  /// @notice Thrown when a caller other than `coordinator.owner()` invokes an admin function.
  error NotCoordinatorOwner();
  /// @notice Thrown when a caller other than the loader or `coordinator.owner()` invokes a loader function.
  error NotLoaderOrCoordinatorOwner();
  /// @notice Thrown when a caller other than `coordinator.stakingContract()` invokes `claimFor`.
  error NotStakingContract();
  /// @notice Thrown when month timestamps are empty or not strictly increasing.
  error InvalidTimestamps();
  /// @notice Thrown when a schedule cliff or existing schedule is incompatible with the timestamp calendar.
  error InvalidSchedule();
  /// @notice Thrown when an explicit unlock curve is malformed.
  error InvalidUnlockCurve();
  /// @notice Thrown when more than 8 schedules are added.
  error ScheduleLimitReached();
  /// @notice Thrown when loading into a schedule that is currently inactive.
  error ScheduleNotActive();
  /// @notice Thrown when a schedule index does not exist.
  error InvalidScheduleType();
  /// @notice Thrown when an address argument is zero.
  error ZeroAddress();
  /// @notice Thrown when an amount argument is zero.
  error ZeroAmount();
  /// @notice Thrown when the packed calldata passed to `loadPositions` is malformed.
  error InvalidData();

  // ====== EVENTS ====== //

  /// @notice Emitted when the shared vesting timestamp calendar is replaced.
  /// @param count Number of timestamps stored.
  event MonthTimestampsSet(uint256 count);
  /// @notice Emitted when a vesting schedule is registered.
  /// @param scheduleType Registered schedule index.
  /// @param cliffMonths  Number of full vesting months before the first positive unlock.
  /// @param label        Human-readable schedule label.
  event VestingScheduleAdded(
    uint8 indexed scheduleType,
    uint8 cliffMonths,
    string label
  );
  /// @notice Emitted when a vesting schedule is activated or deactivated.
  /// @param scheduleType Schedule index updated.
  /// @param active       Whether the schedule accepts new position loads.
  event VestingScheduleStatusUpdated(
    uint8 indexed scheduleType,
    bool active
  );
  /// @notice Emitted when the loader account allowed to load positions is updated.
  /// @param loader New loader account (zero address revokes loading rights).
  event LoaderSet(address indexed loader);
  /// @notice Emitted once per input row in `loadPositions`.
  /// @param user        Beneficiary whose allocation was loaded.
  /// @param scheduleType Schedule index used for the allocation.
  /// @param amount      Token amount loaded in wei.
  event VestingPositionLoaded(
    address indexed user,
    uint8 indexed scheduleType,
    uint256 amount
  );
  /// @notice Emitted when vesting tokens are claimed by the staking contract for a user.
  /// @param user         Beneficiary whose vesting position was claimed.
  /// @param recipient    Address that received the claimed tokens.
  /// @param scheduleType Schedule index claimed from.
  /// @param amount       Token amount claimed in wei.
  event VestingClaimed(
    address indexed user,
    address indexed recipient,
    uint8 indexed scheduleType,
    uint256 amount
  );
  /// @notice Emitted when the coordinator owner performs an emergency token withdrawal.
  /// @param token     ERC-20 token withdrawn from this contract.
  /// @param recipient Address that received the withdrawn tokens.
  /// @param amount    Token amount withdrawn in wei.
  event TokenWithdrawn(
    address indexed token,
    address indexed recipient,
    uint256 amount
  );

  // ====== MODIFIERS ====== //

  /// @dev Restricts a function to the current owner returned by the coordinator.
  modifier onlyCoordinatorOwner() {
    if (msg.sender != coordinator.owner())
      revert NotCoordinatorOwner();
    _;
  }

  /// @dev Restricts a function to the loader or the current owner returned by the coordinator.
  modifier onlyLoaderOrCoordinatorOwner() {
    if (msg.sender != loader && msg.sender != coordinator.owner())
      revert NotLoaderOrCoordinatorOwner();
    _;
  }

  /// @dev Restricts a function to the staking contract registered in the coordinator.
  modifier onlyStakingContract() {
    if (msg.sender != coordinator.stakingContract())
      revert NotStakingContract();
    _;
  }

  // ====== CONSTRUCTOR ====== //

  /// @dev Disables initializers on the implementation contract so it cannot be initialized
  ///      directly. Initialization must happen atomically through the proxy's constructor.
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  // ====== INITIALIZER ====== //

  /// @notice Initialises the contract for proxy deployment.
  /// @param coordinator_      Address of the deployed `SmartWalletCoordinator`.
  /// @param monthTimestamps_  Month-end timestamps shared by all schedules.
  /// @param schedules_        Schedules to register during initialization.
  function initialize(
    address coordinator_,
    uint64[] calldata monthTimestamps_,
    ScheduleInput[] calldata schedules_
  ) external initializer {
    __Pausable_init();
    coordinator = ISmartWalletCoordinator(coordinator_);
    loader = msg.sender;
    emit LoaderSet(msg.sender);
    _setMonthTimestamps(monthTimestamps_);

    uint256 len = schedules_.length;
    for (uint256 i = 0; i < len; i++) {
      ScheduleInput calldata schedule = schedules_[i];
      _addScheduleWithUnlocks(
        schedule.cliffMonths,
        schedule.label,
        schedule.monthlyUnlockPpm
      );
    }
  }

  // ====== ADMIN WRITE FUNCTIONS ====== //

  /// @notice Uploads the month-end timestamps shared by all schedules.
  /// @dev Replaces any previously uploaded array. Timestamps must be strictly increasing.
  ///      Call this before adding schedules or loading positions.
  /// @param timestamps Array of month-end unix timestamps (expected length: 40).
  function setMonthTimestamps(
    uint64[] calldata timestamps
  ) external onlyCoordinatorOwner {
    _setMonthTimestamps(timestamps);
  }

  /// @notice Registers a new vesting schedule defined by its cliff length.
  /// @dev At most 8 schedules (bits in a uint8 bitmask). `cliffMonths` must be ≥ 1 and
  ///      strictly less than `monthTimestamps.length`, guaranteeing at least one vesting period.
  ///      Month timestamps must be uploaded before adding schedules.
  /// @param cliffMonths Number of cliff months (e.g. 2, 3, 4, 5).
  /// @param label       Human-readable label for UI display.
  function addSchedule(
    uint8 cliffMonths,
    string calldata label
  ) external onlyCoordinatorOwner {
    _addSchedule(cliffMonths, label);
  }

  /// @notice Registers a new vesting schedule with explicit per-month unlock weights.
  /// @dev `monthlyUnlockPpm` uses parts-per-million of the full position amount and must sum
  ///      to 1,000,000. Entries before `cliffMonths` must be zero.
  /// @param cliffMonths Number of cliff months before the first positive unlock.
  /// @param label       Human-readable label for UI display.
  /// @param monthlyUnlockPpm Per-month unlock weights, aligned with `monthTimestamps`.
  function addScheduleWithUnlocks(
    uint8 cliffMonths,
    string calldata label,
    uint32[] calldata monthlyUnlockPpm
  ) external onlyCoordinatorOwner {
    _addScheduleWithUnlocks(cliffMonths, label, monthlyUnlockPpm);
  }

  /// @dev Registers a linear vesting schedule for the given cliff.
  function _addSchedule(
    uint8 cliffMonths,
    string calldata label
  ) private {
    if (_schedules.length >= 8) revert ScheduleLimitReached();
    if (cliffMonths == 0 || cliffMonths >= monthTimestamps.length)
      revert InvalidSchedule();

    _schedules.push();
    VestingSchedule storage schedule = _schedules[
      _schedules.length - 1
    ];
    schedule.active = true;
    schedule.cliffMonths = cliffMonths;
    schedule.label = label;

    emit VestingScheduleAdded(
      uint8(_schedules.length - 1),
      cliffMonths,
      label
    );
  }

  /// @dev Registers a vesting schedule with an explicit unlock curve.
  function _addScheduleWithUnlocks(
    uint8 cliffMonths,
    string calldata label,
    uint32[] calldata monthlyUnlockPpm
  ) private {
    if (_schedules.length >= 8) revert ScheduleLimitReached();
    if (cliffMonths == 0 || cliffMonths >= monthTimestamps.length)
      revert InvalidSchedule();

    _schedules.push();
    VestingSchedule storage schedule = _schedules[
      _schedules.length - 1
    ];
    schedule.active = true;
    schedule.cliffMonths = cliffMonths;
    schedule.label = label;
    _storeUnlockCurve(schedule, cliffMonths, monthlyUnlockPpm);

    emit VestingScheduleAdded(
      uint8(_schedules.length - 1),
      cliffMonths,
      label
    );
  }

  /// @notice Activates or deactivates a schedule, controlling whether new positions can be loaded.
  /// @param scheduleType Index of the schedule to update.
  /// @param active       Desired active state.
  function setScheduleActive(
    uint8 scheduleType,
    bool active
  ) external onlyCoordinatorOwner {
    if (scheduleType >= _schedules.length)
      revert InvalidScheduleType();
    _schedules[scheduleType].active = active;
    emit VestingScheduleStatusUpdated(scheduleType, active);
  }

  /// @notice Updates the loader account allowed to load positions.
  /// @dev Callable by the current loader or the coordinator owner, so loading rights can
  ///      be rotated without moving coordinator ownership. Zero address revokes them.
  /// @param newLoader Account allowed to call `loadPositions`.
  function setLoader(address newLoader) external onlyLoaderOrCoordinatorOwner {
    loader = newLoader;
    emit LoaderSet(newLoader);
  }

  /// @notice Batch-loads vesting allocations from custom-packed calldata.
  /// @dev Encoding: for each beneficiary — address (20 bytes), count (1 byte),
  ///      then count × [scheduleType (1 byte) + amount (12 bytes, uint96, big-endian)].
  ///      Multiple entries for the same (beneficiary, scheduleType) are additive.
  ///      Using packed bytes instead of ABI-encoded structs cuts calldata by ~76%.
  function loadPositions(bytes calldata data) external onlyLoaderOrCoordinatorOwner whenNotPaused {
    uint256 cdBase;
    assembly { cdBase := data.offset }
    uint256 end = data.length;
    uint256 offset;

    while (offset < end) {
      if (offset + 21 > end) revert InvalidData();

      address beneficiary;
      assembly { beneficiary := shr(96, calldataload(add(cdBase, offset))) }
      if (beneficiary == address(0)) revert ZeroAddress();
      offset += 20;

      uint256 count;
      assembly { count := byte(0, calldataload(add(cdBase, offset))) }
      offset += 1;
      if (offset + count * 13 > end) revert InvalidData();

      for (uint256 i; i < count; ++i) {
        uint8 scheduleType;
        assembly { scheduleType := byte(0, calldataload(add(cdBase, offset))) }
        offset += 1;

        // Read 12 bytes big-endian as uint96, then widen to uint128.
        uint128 amount;
        assembly { amount := shr(160, calldataload(add(cdBase, offset))) }
        offset += 12;

        if (amount == 0) revert ZeroAmount();
        if (scheduleType >= _schedules.length) revert InvalidScheduleType();
        if (!_schedules[scheduleType].active) revert ScheduleNotActive();

        // amount is capped at uint96 by the encoding; overflowing the uint128
        // totalAmount would take ~4 billion max-value loads, and checked
        // arithmetic still reverts if it ever happened.
        VestingPosition storage pos = _positions[beneficiary][scheduleType];
        pos.totalAmount += uint128(amount);
        userScheduleMask[beneficiary] |= (uint8(1) << scheduleType);
        emit VestingPositionLoaded(beneficiary, scheduleType, uint256(amount));
      }
    }
  }

  /// @notice Pauses all state-changing vesting operations.
  function pause() external onlyCoordinatorOwner {
    _pause();
  }

  /// @notice Resumes state-changing vesting operations after a pause.
  function unpause() external onlyCoordinatorOwner {
    _unpause();
  }

  /// @notice Emergency admin withdrawal for any ERC-20 held by this contract.
  /// @dev Intentionally permits withdrawing tokens backing vesting positions. This is a
  ///      break-glass action and can leave vesting claims underfunded.
  /// @param token_    ERC-20 token to withdraw.
  /// @param recipient Address that receives the withdrawn tokens.
  /// @param amount    Token amount to withdraw in wei.
  function withdrawToken(
    address token_,
    address recipient,
    uint256 amount
  ) external onlyCoordinatorOwner {
    if (token_ == address(0) || recipient == address(0))
      revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();

    IERC20(token_).safeTransfer(recipient, amount);
    emit TokenWithdrawn(token_, recipient, amount);
  }

  // ====== STAKING-CONTRACT-ONLY WRITE FUNCTIONS ====== //

  /// @notice Claims up to `amount` tokens from the caller's vesting positions.
  /// @dev Iterates schedule types in registration order (at most 8). State is updated before
  ///      the token transfer (CEI).
  /// @param user   Beneficiary whose positions are drawn.
  /// @param amount Maximum tokens to claim (in wei). Pass `type(uint256).max` to claim all.
  /// @return claimed Actual amount of tokens transferred.
  function claimFor(
    address user,
    uint256 amount
  )
    external
    onlyStakingContract
    whenNotPaused
    returns (uint256 claimed)
  {
    uint8 mask = userScheduleMask[user];
    if (mask == 0) return 0;

    uint256 remaining = amount;
    uint8 numSchedules = uint8(_schedules.length);
    uint256 elapsedMonths = _elapsedMonthCount();

    for (uint8 s = 0; s < numSchedules && remaining > 0; s++) {
      if (mask & (uint8(1) << s) == 0) continue;

      VestingPosition storage pos = _positions[user][s];
      uint256 vested = _vestedFor(pos, _schedules[s], elapsedMonths);
      uint256 claimable = vested > pos.claimedAmount
        ? vested - pos.claimedAmount
        : 0;
      if (claimable == 0) continue;

      uint256 take = claimable < remaining ? claimable : remaining;
      pos.claimedAmount += uint128(take);
      claimed += take;
      remaining -= take;

      emit VestingClaimed(user, msg.sender, s, take);
    }

    if (claimed > 0)
      coordinator.stakingToken().safeTransfer(msg.sender, claimed);
  }

  // ====== READ FUNCTIONS ====== //

  /// @notice Returns the platform token used for all vesting transfers.
  /// @return The ERC-20 token address read from `coordinator.stakingToken()`.
  function token() external view returns (IERC20) {
    return coordinator.stakingToken();
  }

  /// @notice Returns the number of registered schedules.
  /// @return Number of schedules currently registered.
  function scheduleCount() external view returns (uint256) {
    return _schedules.length;
  }

  /// @notice Returns the number of uploaded month timestamps.
  /// @return Number of timestamps in the shared vesting calendar.
  function monthTimestampsLength() external view returns (uint256) {
    return monthTimestamps.length;
  }

  /// @notice Returns the schedule definition for a given type.
  /// @param scheduleType Schedule index to read.
  /// @return Schedule definition.
  function getSchedule(
    uint8 scheduleType
  ) external view returns (VestingSchedule memory) {
    return _schedules[scheduleType];
  }

  /// @notice Returns the raw packed position for a (user, scheduleType) pair.
  /// @param user         Beneficiary address.
  /// @param scheduleType Schedule index to read.
  /// @return Packed vesting position.
  function getPosition(
    address user,
    uint8 scheduleType
  ) external view returns (VestingPosition memory) {
    return _positions[user][scheduleType];
  }

  /// @notice Returns the computed position view for a (user, scheduleType) pair.
  /// @param user         Beneficiary address.
  /// @param scheduleType Schedule index to read.
  /// @return Computed vesting position view.
  function getPositionView(
    address user,
    uint8 scheduleType
  ) external view returns (VestingPositionView memory) {
    return
      _buildPositionView(user, scheduleType, _elapsedMonthCount());
  }

  /// @notice Returns computed views for all schedule types in which the user has a position.
  /// @param user Beneficiary address.
  /// @return views Computed vesting position views.
  function getAllPositionViews(
    address user
  ) external view returns (VestingPositionView[] memory views) {
    uint8 mask = userScheduleMask[user];
    uint8 numSchedules = uint8(_schedules.length);

    uint8 count = 0;
    for (uint8 s = 0; s < numSchedules; s++) {
      if (mask & (uint8(1) << s) != 0) count++;
    }
    views = new VestingPositionView[](count);

    uint8 idx = 0;
    uint256 elapsedMonths = _elapsedMonthCount();
    for (uint8 s = 0; s < numSchedules; s++) {
      if (mask & (uint8(1) << s) == 0) continue;
      views[idx++] = _buildPositionView(user, s, elapsedMonths);
    }
  }

  /// @notice Returns the total tokens remaining across all of a user's positions
  ///         (`totalAmount - claimedAmount` summed). Used for VIP balance calculations —
  ///         unclaimed vested tokens are still held in this contract.
  /// @param user Beneficiary address.
  /// @return total Remaining unclaimed amount in wei.
  function unclaimedBalanceOf(
    address user
  ) external view returns (uint256 total) {
    uint8 mask = userScheduleMask[user];
    uint8 numSchedules = uint8(_schedules.length);
    for (uint8 s = 0; s < numSchedules; s++) {
      if (mask & (uint8(1) << s) == 0) continue;
      VestingPosition storage pos = _positions[user][s];
      total += pos.totalAmount - pos.claimedAmount;
    }
  }

  /// @notice Returns the total amount immediately claimable across all of a user's positions.
  /// @param user Beneficiary address.
  /// @return total Immediately claimable amount in wei.
  function claimableBalanceOf(
    address user
  ) external view returns (uint256 total) {
    uint8 mask = userScheduleMask[user];
    uint8 numSchedules = uint8(_schedules.length);
    uint256 elapsedMonths = _elapsedMonthCount();
    for (uint8 s = 0; s < numSchedules; s++) {
      if (mask & (uint8(1) << s) == 0) continue;
      VestingPosition storage pos = _positions[user][s];
      uint256 vested = _vestedFor(pos, _schedules[s], elapsedMonths);
      if (vested > pos.claimedAmount)
        total += vested - pos.claimedAmount;
    }
  }

  // ====== INTERNAL HELPERS ====== //

  /// @dev Computes the vested amount for a position at `block.timestamp`.
  ///      Vesting starts at the end of month `cliffMonths + 1` (monthTimestamps[cliffMonths]).
  ///      Each elapsed month releases 1/vestingPeriods of totalAmount.
  ///      Returns totalAmount directly when all periods have elapsed to avoid dust.
  function _vestedFor(
    VestingPosition storage pos,
    VestingSchedule storage sched,
    uint256 elapsedMonths
  ) internal view returns (uint256) {
    if (pos.totalAmount == 0) return 0;

    uint8 cliffMonths = sched.cliffMonths;
    uint256 totalMonths = monthTimestamps.length;
    if (elapsedMonths <= cliffMonths) return 0;

    if (sched.cumulativeUnlockPpm.length != 0) {
      return _vestedForUnlockCurve(pos, sched, elapsedMonths);
    }

    uint256 vestingPeriods = totalMonths - cliffMonths;
    uint256 elapsedVestingPeriods = elapsedMonths - cliffMonths;
    if (elapsedVestingPeriods >= vestingPeriods)
      return pos.totalAmount;
    return
      (uint256(pos.totalAmount) * elapsedVestingPeriods) /
      vestingPeriods;
  }

  /// @dev Computes the vested amount for a position using a stored cumulative unlock curve.
  function _vestedForUnlockCurve(
    VestingPosition storage pos,
    VestingSchedule storage sched,
    uint256 elapsedMonths
  ) internal view returns (uint256) {
    uint256 cumulativePpm = sched.cumulativeUnlockPpm[
      elapsedMonths - 1
    ];

    if (cumulativePpm >= UNLOCK_PPM_DENOMINATOR)
      return pos.totalAmount;
    return
      (uint256(pos.totalAmount) * cumulativePpm) /
      UNLOCK_PPM_DENOMINATOR;
  }

  /// @dev Assembles a `VestingPositionView` for a (user, scheduleType) pair.
  function _buildPositionView(
    address user,
    uint8 s,
    uint256 elapsedMonths
  ) internal view returns (VestingPositionView memory v) {
    VestingSchedule storage sched = _schedules[s];
    VestingPosition storage pos = _positions[user][s];

    uint8 cliffMonths = sched.cliffMonths;
    uint256 vestingPeriods = monthTimestamps.length - cliffMonths;
    uint256 vested = _vestedFor(pos, sched, elapsedMonths);
    uint256 claimable = vested > pos.claimedAmount
      ? vested - pos.claimedAmount
      : 0;

    v = VestingPositionView({
      scheduleType: s,
      cliffMonths: cliffMonths,
      vestingPeriods: vestingPeriods,
      label: sched.label,
      totalAmount: pos.totalAmount,
      claimedAmount: pos.claimedAmount,
      vestedAmount: vested,
      claimableAmount: claimable,
      lockedAmount: pos.totalAmount - vested,
      nextReleaseAt: _nextReleaseAt(sched, elapsedMonths)
    });
  }

  /// @dev Replaces the shared timestamp calendar after validating ordering and schedule compatibility.
  function _setMonthTimestamps(uint64[] calldata timestamps) private {
    uint256 len = timestamps.length;
    if (len == 0) revert InvalidTimestamps();
    for (uint256 i = 1; i < len; i++) {
      if (timestamps[i] <= timestamps[i - 1])
        revert InvalidTimestamps();
    }

    uint256 scheduleLen = _schedules.length;
    for (uint256 i = 0; i < scheduleLen; i++) {
      VestingSchedule storage schedule = _schedules[i];
      if (schedule.cliffMonths >= len) revert InvalidSchedule();
      if (
        schedule.cumulativeUnlockPpm.length != 0 &&
        schedule.cumulativeUnlockPpm.length != len
      ) revert InvalidUnlockCurve();
    }

    delete monthTimestamps;
    for (uint256 i = 0; i < len; i++) {
      monthTimestamps.push(timestamps[i]);
    }
    emit MonthTimestampsSet(len);
  }

  /// @dev Stores cumulative unlock percentages derived from a per-month unlock curve.
  function _storeUnlockCurve(
    VestingSchedule storage schedule,
    uint8 cliffMonths,
    uint32[] calldata monthlyUnlockPpm
  ) private {
    uint256 len = monthlyUnlockPpm.length;
    if (len != monthTimestamps.length) revert InvalidUnlockCurve();

    uint256 cumulativePpm = 0;
    bool hasUnlock = false;
    for (uint256 i = 0; i < len; i++) {
      uint32 unlockPpm = monthlyUnlockPpm[i];
      if (i < cliffMonths && unlockPpm != 0)
        revert InvalidUnlockCurve();
      if (unlockPpm != 0) hasUnlock = true;

      cumulativePpm += unlockPpm;
      if (cumulativePpm > UNLOCK_PPM_DENOMINATOR)
        revert InvalidUnlockCurve();

      schedule.cumulativeUnlockPpm.push(uint32(cumulativePpm));
    }

    if (!hasUnlock || cumulativePpm != UNLOCK_PPM_DENOMINATOR)
      revert InvalidUnlockCurve();
  }

  /// @dev Returns how many month timestamps are less than or equal to the current timestamp.
  function _elapsedMonthCount() private view returns (uint256) {
    uint256 ts = block.timestamp;
    uint256 low = 0;
    uint256 high = monthTimestamps.length;

    while (low < high) {
      uint256 mid = (low + high) / 2;
      if (monthTimestamps[mid] <= ts) low = mid + 1;
      else high = mid;
    }

    return low;
  }

  /// @dev Returns the next timestamp that increases the schedule's vested amount, or 0 when complete.
  function _nextReleaseAt(
    VestingSchedule storage sched,
    uint256 elapsedMonths
  ) private view returns (uint64) {
    uint256 totalMonths = monthTimestamps.length;
    if (elapsedMonths >= totalMonths) return 0;

    if (sched.cumulativeUnlockPpm.length == 0) {
      uint256 nextIndex = elapsedMonths > sched.cliffMonths
        ? elapsedMonths
        : sched.cliffMonths;
      return
        nextIndex < totalMonths
          ? monthTimestamps[nextIndex]
          : uint64(0);
    }

    uint32 currentPpm = elapsedMonths == 0
      ? 0
      : sched.cumulativeUnlockPpm[elapsedMonths - 1];
    for (uint256 i = elapsedMonths; i < totalMonths; i++) {
      if (sched.cumulativeUnlockPpm[i] > currentPpm)
        return monthTimestamps[i];
    }

    return 0;
  }
}
