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

/// @title Staking
/// @notice Holds direct staking deposits and acts as the single gateway for withdrawals,
///         vesting claims, and combined account reads. Users never interact with
///         `VestingDistributor` directly — all claim paths flow through this contract.
/// @dev Deployed as a transparent proxy. Admin identity is read from
///      `SmartWalletCoordinator.owner()` at call time; there is no local owner storage.
///      `lockDuration` applies only to future deposits; existing positions are unaffected by
///      any subsequent `setLockDuration` call.
contract Staking is Initializable, PausableUpgradeable {
  using SafeERC20 for IERC20;

  // ====== STORAGE ====== //

  /// @notice The coordinator contract from which admin identity, the staking token and
  ///         the vesting contract are read.
  ISmartWalletCoordinator public coordinator;

  /// @notice Seconds added to `block.timestamp` to compute `unlockAt` for new deposits.
  uint64 public lockDuration;

  /// @dev Staking positions keyed by position ID.
  mapping(bytes32 => StakingPosition) private _positions;

  /// @dev Ordered list of position IDs for each depositor.
  mapping(address => bytes32[]) private _userPositionIds;

  /// @notice Monotonic counter used as the nonce when deriving position IDs.
  uint256 public nextPositionId;

  // ====== STRUCTS ====== //

  /// @notice A direct staking deposit with its own lock and withdrawal state.
  struct StakingPosition {
    /// @dev `keccak256(abi.encodePacked(address(this), nonce))`.
    bytes32 positionId;
    /// @notice Address that created and owns the staking position.
    address owner;
    /// @notice Original deposited token amount in wei.
    uint256 amount;
    /// @notice Amount already withdrawn from this position in wei.
    uint256 withdrawnAmount;
    /// @notice Timestamp when the position was created.
    uint64 depositedAt;
    /// @notice Earliest timestamp when this position can be withdrawn.
    uint64 unlockAt;
  }

  /// @notice Aggregated staking and vesting balances for one user.
  struct UserStakeSummary {
    /// @dev vestingUnclaimed + stakingLocked + stakingWithdrawable.
    uint256 totalVipStake;
    /// @dev Tokens remaining in VestingDistributor lots (vested or not yet vested).
    uint256 vestingUnclaimed;
    /// @dev Subset of vestingUnclaimed that can be claimed right now.
    uint256 vestingClaimable;
    /// @notice Direct staking amount still locked.
    uint256 stakingLocked;
    /// @notice Direct staking amount unlocked and available to withdraw.
    uint256 stakingWithdrawable;
    /// @notice Direct staking amount already withdrawn.
    uint256 stakingWithdrawn;
  }

  /// @notice Full staking and vesting position details for one user.
  struct UserStakeDetails {
    /// @notice Aggregated account summary.
    UserStakeSummary summary;
    /// @dev All vesting positions (max 4 — one per schedule type in which the user has an allocation).
    IVestingDistributor.VestingPositionView[] vestingPositions;
    /// @notice All direct staking positions for the user.
    StakingPosition[] stakingPositions;
  }

  /// @notice Paginated variant of `UserStakeDetails` — returned by `getUserStakeDetailsPage`.
  /// @dev Vesting positions are always returned in full (max 4); only staking positions are windowed.
  struct UserStakeDetailsPage {
    /// @notice Aggregated account summary.
    UserStakeSummary summary;
    /// @dev Total staking position count regardless of the requested window.
    uint256 stakingPositionCount;
    /// @notice All vesting positions for the user.
    IVestingDistributor.VestingPositionView[] vestingPositions;
    /// @notice Requested window of direct staking positions for the user.
    StakingPosition[] stakingPositions;
  }

  // ====== ERRORS ====== //

  /// @notice Thrown when a caller other than `coordinator.owner()` invokes an admin function.
  error NotCoordinatorOwner();

  /// @notice Thrown when a zero amount is passed to `deposit` or `unlock`.
  error ZeroAmount();

  /// @notice Thrown when `unlock` finds no claimable vesting or withdrawable staking for the caller.
  error NothingUnlockable();

  /// @notice Thrown when an address argument is zero.
  error ZeroAddress();

  // ====== EVENTS ====== //

  /// @notice Emitted when the lock duration for future deposits changes.
  /// @param oldDuration Previous duration in seconds.
  /// @param newDuration New duration in seconds.
  event StakingLockDurationUpdated(
    uint64 oldDuration,
    uint64 newDuration
  );

  /// @notice Emitted when a new staking position is created via `deposit`.
  /// @param positionId Unique identifier of the new position.
  /// @param user       Address of the depositor.
  /// @param amount     Tokens deposited in wei.
  /// @param unlockAt   Earliest timestamp at which the position may be withdrawn.
  event StakingPositionCreated(
    bytes32 indexed positionId,
    address indexed user,
    uint256 amount,
    uint64 unlockAt
  );

  /// @notice Emitted once per position whenever tokens are withdrawn from it.
  /// @param positionId Identifier of the affected position.
  /// @param user       Owner of the position.
  /// @param recipient  Address that received the tokens.
  /// @param amount     Tokens withdrawn in wei.
  event StakingPositionWithdrawn(
    bytes32 indexed positionId,
    address indexed user,
    address indexed recipient,
    uint256 amount
  );

  /// @notice Emitted at the end of every `unlock` call.
  /// @param user        Caller who initiated the withdrawal.
  /// @param recipient   Address that received the tokens (currently always `user`).
  /// @param requested   Amount requested by the caller.
  /// @param fromVesting Tokens sourced from vesting claims.
  /// @param fromStaking Tokens sourced from direct staking positions.
  event TokensUnlocked(
    address indexed user,
    address indexed recipient,
    uint256 requested,
    uint256 fromVesting,
    uint256 fromStaking
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

  // ====== CONSTRUCTOR ====== //

  /// @dev Disables initializers on the implementation contract so it cannot be initialized
  ///      directly. Initialization must happen atomically through the proxy's constructor.
  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  // ====== INITIALIZER ====== //

  /// @notice Initialises the contract for proxy deployment.
  /// @dev The vesting contract is not stored here — it is resolved at call time from
  ///      `coordinator.vestingContract()`.
  /// @param coordinator_ Address of the deployed `SmartWalletCoordinator`.
  /// @param lockDuration_ Initial lock period for new staking deposits.
  function initialize(
    address coordinator_,
    uint64 lockDuration_
  ) external initializer {
    __Pausable_init();
    coordinator = ISmartWalletCoordinator(coordinator_);
    lockDuration = lockDuration_;
    emit StakingLockDurationUpdated(0, lockDuration_);
  }

  // ====== USER WRITE FUNCTIONS ====== //

  /// @notice Opens a new time-locked staking position.
  /// @dev Pulls `amount` of the staking token from the caller via `transferFrom`. The caller
  ///      must approve this contract before calling. A unique position ID is derived from a
  ///      monotonic nonce. `lockDuration` at deposit time determines `unlockAt`.
  /// @param amount Token amount to stake in wei.
  function deposit(uint256 amount) public whenNotPaused {
    if (amount == 0) revert ZeroAmount();
    coordinator.stakingToken().safeTransferFrom(
      msg.sender,
      address(this),
      amount
    );

    uint64 unlockAt = uint64(block.timestamp) + lockDuration;
    bytes32 positionId = keccak256(
      abi.encodePacked(address(this), nextPositionId++)
    );

    _positions[positionId] = StakingPosition({
      positionId: positionId,
      owner: msg.sender,
      amount: amount,
      withdrawnAmount: 0,
      depositedAt: uint64(block.timestamp),
      unlockAt: unlockAt
    });
    _userPositionIds[msg.sender].push(positionId);

    emit StakingPositionCreated(
      positionId,
      msg.sender,
      amount,
      unlockAt
    );
  }

  /// @notice Alias for `deposit` — satisfies the `IStaking` interface consumed by SmartWallet.
  /// @dev Pause state is enforced by `deposit`.
  /// @param amount Token amount to stake in wei.
  function stake(uint256 amount) external {
    deposit(amount);
  }

  /// @notice Withdraws up to `amount` tokens to the caller, claiming vesting first.
  /// @dev Priority order: (1) claimable vesting, (2) unlocked direct staking.
  ///      Locked vesting and locked direct staking are never touched.
  ///      Vesting tokens are transferred here first; staking tokens are already held here.
  ///      A single outbound transfer is made to the caller after all state is updated (CEI).
  ///      Reverts if nothing can be unlocked (no claimable vesting and no withdrawable staking).
  /// @param amount Maximum tokens to withdraw in wei.
  /// @return unlocked Actual amount of tokens transferred.
  function unlock(
    uint256 amount
  ) public whenNotPaused returns (uint256 unlocked) {
    if (amount == 0) revert ZeroAmount();
    address user = msg.sender;
    uint256 remaining = amount;

    uint256 fromVesting = vesting().claimFor(user, remaining);
    remaining -= fromVesting;

    uint256 fromStaking = _collectUnlockedStaking(user, remaining);

    unlocked = fromVesting + fromStaking;
    if (unlocked == 0) revert NothingUnlockable();

    coordinator.stakingToken().safeTransfer(user, unlocked);
    emit TokensUnlocked(user, user, amount, fromVesting, fromStaking);
  }

  /// @notice Alias for `unlock` — satisfies the `IStaking` interface consumed by SmartWallet.
  /// @dev Pause state is enforced by `unlock`.
  /// @param amount Token amount to withdraw in wei.
  function unstake(uint256 amount) external {
    unlock(amount);
  }

  // ====== ADMIN WRITE FUNCTIONS ====== //

  /// @notice Updates the lock duration applied to future deposits.
  /// @dev Existing positions are not affected.
  /// @param duration New lock period in seconds.
  function setLockDuration(
    uint64 duration
  ) external onlyCoordinatorOwner {
    emit StakingLockDurationUpdated(lockDuration, duration);
    lockDuration = duration;
  }

  /// @notice Pauses deposits and unlocks.
  function pause() external onlyCoordinatorOwner {
    _pause();
  }

  /// @notice Resumes deposits and unlocks after a pause.
  function unpause() external onlyCoordinatorOwner {
    _unpause();
  }

  /// @notice Emergency admin withdrawal for any ERC-20 held by this contract.
  /// @dev Intentionally permits withdrawing tokens backing direct staking positions. This is a
  ///      break-glass action and can leave staking withdrawals underfunded.
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

  // ====== READ FUNCTIONS ====== //

  /// @notice Returns the platform token used for deposits and withdrawals.
  /// @return The ERC-20 token address read from `coordinator.stakingToken()`.
  function token() external view returns (IERC20) {
    return coordinator.stakingToken();
  }

  /// @notice Returns the vesting contract used for claims and combined balance reads.
  /// @return The `VestingDistributor` address read from `coordinator.vestingContract()`.
  function vesting() public view returns (IVestingDistributor) {
    return IVestingDistributor(coordinator.vestingContract());
  }

  /// @dev Returns direct staking balance still locked for `user`.
  function _stakingLockedBalanceOf(
    address user
  ) internal view returns (uint256 total) {
    bytes32[] storage ids = _userPositionIds[user];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
      StakingPosition storage pos = _positions[ids[i]];
      if (block.timestamp < pos.unlockAt)
        total += pos.amount - pos.withdrawnAmount;
    }
  }

  /// @dev Returns direct staking balance currently withdrawable for `user`.
  function _stakingWithdrawableBalanceOf(
    address user
  ) internal view returns (uint256 total) {
    bytes32[] storage ids = _userPositionIds[user];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
      StakingPosition storage pos = _positions[ids[i]];
      if (block.timestamp >= pos.unlockAt)
        total += pos.amount - pos.withdrawnAmount;
    }
  }

  /// @dev Returns all unwithdrawn direct staking balance for `user`.
  function _directStakedBalanceOf(
    address user
  ) internal view returns (uint256 total) {
    bytes32[] storage ids = _userPositionIds[user];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
      total +=
        _positions[ids[i]].amount -
        _positions[ids[i]].withdrawnAmount;
    }
  }

  /// @notice Returns the combined staked balance used for protocol-level accounting.
  /// @dev Equals `vesting.unclaimedBalanceOf(user) + direct staking balance`.
  /// @param user Account address.
  /// @return Combined staked balance in wei.
  function totalStakedBalanceOf(
    address user
  ) external view returns (uint256) {
    return
      vesting().unclaimedBalanceOf(user) + _directStakedBalanceOf(user);
  }

  /// @notice Returns the aggregated staking and vesting summary for VIP and UI purposes.
  /// @dev `totalVipStake = vestingUnclaimed + stakingLocked + stakingWithdrawable`.
  ///      Tokens already withdrawn are excluded from VIP calculations.
  /// @param user Account address.
  /// @return Populated `UserStakeSummary`.
  function getUserStakeSummary(
    address user
  ) public view returns (UserStakeSummary memory) {
    IVestingDistributor vesting_ = vesting();
    uint256 vestingUnclaimed = vesting_.unclaimedBalanceOf(user);
    uint256 vestingClaimable = vesting_.claimableBalanceOf(user);
    uint256 locked = _stakingLockedBalanceOf(user);
    uint256 withdrawable = _stakingWithdrawableBalanceOf(user);

    uint256 withdrawn;
    bytes32[] storage ids = _userPositionIds[user];
    uint256 len = ids.length;
    for (uint256 i = 0; i < len; i++) {
      withdrawn += _positions[ids[i]].withdrawnAmount;
    }

    return
      UserStakeSummary({
        totalVipStake: vestingUnclaimed + locked + withdrawable,
        vestingUnclaimed: vestingUnclaimed,
        vestingClaimable: vestingClaimable,
        stakingLocked: locked,
        stakingWithdrawable: withdrawable,
        stakingWithdrawn: withdrawn
      });
  }

  /// @notice Returns the full account details in a single call.
  /// @param user Account address.
  /// @return details Summary, all vesting positions (max 4), all staking positions.
  function getUserStakeDetails(
    address user
  ) external view returns (UserStakeDetails memory details) {
    details.summary = getUserStakeSummary(user);
    details.vestingPositions = vesting().getAllPositionViews(user);
    details.stakingPositions = _slicePositions(
      user,
      0,
      type(uint256).max
    );
  }

  /// @notice Returns a paginated window of account details.
  /// @dev The `summary` and `stakingPositionCount` always reflect the full account.
  ///      Vesting positions are always returned in full (max 4); only staking positions are windowed.
  /// @param user           Account address.
  /// @param positionOffset Zero-based index of the first staking position to include.
  /// @param positionLimit  Maximum number of staking positions to return.
  /// @return page Paginated `UserStakeDetailsPage`.
  function getUserStakeDetailsPage(
    address user,
    uint256 positionOffset,
    uint256 positionLimit
  ) external view returns (UserStakeDetailsPage memory page) {
    page.summary = getUserStakeSummary(user);
    page.stakingPositionCount = _userPositionIds[user].length;
    page.vestingPositions = vesting().getAllPositionViews(user);
    page.stakingPositions = _slicePositions(
      user,
      positionOffset,
      positionLimit
    );
  }

  // ====== INTERNAL HELPERS ====== //

  /// @dev Accounts for up to `remaining` tokens from the caller's unlocked staking positions.
  ///      Updates withdrawnAmount on each eligible position; the caller is responsible for
  ///      the actual token transfer.
  function _collectUnlockedStaking(
    address user,
    uint256 remaining
  ) internal returns (uint256 collected) {
    if (remaining == 0) return 0;
    bytes32[] storage ids = _userPositionIds[user];
    uint256 len = ids.length;

    for (uint256 i = 0; i < len && remaining > 0; i++) {
      StakingPosition storage pos = _positions[ids[i]];
      if (block.timestamp < pos.unlockAt) continue;
      uint256 available = pos.amount - pos.withdrawnAmount;
      if (available == 0) continue;

      uint256 take = available < remaining ? available : remaining;
      pos.withdrawnAmount += take;
      collected += take;
      remaining -= take;

      emit StakingPositionWithdrawn(ids[i], user, user, take);
    }
  }

  /// @dev Returns a window of staking positions for a user.
  ///      `limit == type(uint256).max` returns all positions from `offset` onwards.
  function _slicePositions(
    address user,
    uint256 offset,
    uint256 limit
  ) internal view returns (StakingPosition[] memory result) {
    bytes32[] storage ids = _userPositionIds[user];
    uint256 total = ids.length;
    if (offset >= total) return new StakingPosition[](0);

    uint256 end = limit > total - offset ? total : offset + limit;
    uint256 count = end - offset;
    result = new StakingPosition[](count);
    for (uint256 i = 0; i < count; i++) {
      result[i] = _positions[ids[offset + i]];
    }
  }
}
