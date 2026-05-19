// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Optimized Multi-Reward ERC20 Staking Contract
    -------------------------------------------------------
    Features:
    - Solidity 0.8.x
    - ReentrancyGuard
    - Pausable
    - Custom Errors
    - Gas Optimized
    - Multi reward support
    - Safe reward accounting
    - Reward debt architecture
    - Emergency recovery
    - Permit-ready structure
*/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

contract ERC20StakingRewardsDistribution is
    ReentrancyGuard,
    Pausable,
    Ownable2Step
{
    using SafeERC20 for IERC20;

    // =============================================================
    //                           ERRORS
    // =============================================================

    error InvalidAddress();
    error InvalidAmount();
    error InvalidDuration();
    error InvalidTimestamp();
    error PoolNotStarted();
    error PoolEnded();
    error PoolCanceled();
    error PoolStillRunning();
    error StakingCapExceeded();
    error NothingToClaim();
    error InsufficientStake();
    error DuplicateRewardToken();

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    uint256 private constant PRECISION = 1e18;

    // =============================================================
    //                          STRUCTS
    // =============================================================

    struct RewardPool {
        IERC20 token;
        uint256 rewardRate;
        uint256 totalRewards;
        uint256 accRewardPerShare;
        uint256 lastUpdateTime;
        uint256 distributedRewards;
    }

    struct UserInfo {
        uint256 amount;
        mapping(uint256 => uint256) rewardDebt;
        mapping(uint256 => uint256) pendingRewards;
    }

    // =============================================================
    //                         STORAGE
    // =============================================================

    IERC20 public immutable stakingToken;

    RewardPool[] public rewardPools;

    mapping(address => UserInfo) private users;
    mapping(address => bool) public rewardTokenExists;

    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable duration;

    uint256 public totalStaked;
    uint256 public stakingCap;

    bool public locked;
    bool public canceled;

    // =============================================================
    //                           EVENTS
    // =============================================================

    event Staked(
        address indexed user,
        uint256 amount
    );

    event Withdrawn(
        address indexed user,
        uint256 amount
    );

    event RewardClaimed(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    event EmergencyWithdraw(
        address indexed user,
        uint256 amount
    );

    event PoolCanceled();

    event RewardsRecovered(
        address indexed token,
        uint256 amount
    );

    // =============================================================
    //                        CONSTRUCTOR
    // =============================================================

    constructor(
        address _stakingToken,
        address[] memory _rewardTokens,
        uint256[] memory _rewardAmounts,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _stakingCap,
        bool _locked
    ) {
        if (_stakingToken == address(0))
            revert InvalidAddress();

        if (_rewardTokens.length != _rewardAmounts.length)
            revert InvalidAmount();

        if (_startTime <= block.timestamp)
            revert InvalidTimestamp();

        if (_endTime <= _startTime)
            revert InvalidDuration();

        stakingToken = IERC20(_stakingToken);

        startTime = _startTime;
        endTime = _endTime;
        duration = _endTime - _startTime;

        stakingCap = _stakingCap;
        locked = _locked;

        uint256 length = _rewardTokens.length;

        for (uint256 i; i < length;) {

            address rewardToken = _rewardTokens[i];
            uint256 rewardAmount = _rewardAmounts[i];

            if (rewardToken == address(0))
                revert InvalidAddress();

            if (rewardAmount == 0)
                revert InvalidAmount();

            if (rewardTokenExists[rewardToken])
                revert DuplicateRewardToken();

            rewardTokenExists[rewardToken] = true;

            IERC20(rewardToken).safeTransferFrom(
                msg.sender,
                address(this),
                rewardAmount
            );

            rewardPools.push(
                RewardPool({
                    token: IERC20(rewardToken),
                    rewardRate: rewardAmount / duration,
                    totalRewards: rewardAmount,
                    accRewardPerShare: 0,
                    lastUpdateTime: _startTime,
                    distributedRewards: 0
                })
            );

            unchecked {
                ++i;
            }
        }

        _transferOwnership(msg.sender);
    }

    // =============================================================
    //                        MODIFIERS
    // =============================================================

    modifier onlyRunning() {
        if (canceled)
            revert PoolCanceled();

        if (block.timestamp < startTime)
            revert PoolNotStarted();

        if (block.timestamp > endTime)
            revert PoolEnded();

        _;
    }

    // =============================================================
    //                    INTERNAL ACCOUNTING
    // =============================================================

    function _updatePool() internal {

        uint256 poolLength = rewardPools.length;

        if (totalStaked == 0) {
            for (uint256 i; i < poolLength;) {
                rewardPools[i].lastUpdateTime = _lastApplicableTime();

                unchecked {
                    ++i;
                }
            }

            return;
        }

        for (uint256 i; i < poolLength;) {

            RewardPool storage pool = rewardPools[i];

            uint256 currentTime =
                _lastApplicableTime();

            if (currentTime <= pool.lastUpdateTime) {

                unchecked {
                    ++i;
                }

                continue;
            }

            uint256 elapsed =
                currentTime - pool.lastUpdateTime;

            uint256 reward =
                elapsed * pool.rewardRate;

            pool.accRewardPerShare +=
                (reward * PRECISION) / totalStaked;

            pool.lastUpdateTime = currentTime;

            unchecked {
                ++i;
            }
        }
    }

    function _updateUser(
        address userAddress
    ) internal {

        UserInfo storage user =
            users[userAddress];

        uint256 poolLength =
            rewardPools.length;

        for (uint256 i; i < poolLength;) {

            RewardPool storage pool =
                rewardPools[i];

            uint256 accumulated =
                (user.amount *
                    pool.accRewardPerShare)
                    / PRECISION;

            uint256 pending =
                accumulated -
                user.rewardDebt[i];

            if (pending > 0) {
                user.pendingRewards[i] += pending;
            }

            user.rewardDebt[i] = accumulated;

            unchecked {
                ++i;
            }
        }
    }

    function _lastApplicableTime()
        internal
        view
        returns (uint256)
    {
        return block.timestamp < endTime
            ? block.timestamp
            : endTime;
    }

    // =============================================================
    //                           STAKE
    // =============================================================

    function stake(
        uint256 amount
    )
        external
        nonReentrant
        whenNotPaused
        onlyRunning
    {

        if (amount == 0)
            revert InvalidAmount();

        if (
            stakingCap > 0 &&
            totalStaked + amount > stakingCap
        ) {
            revert StakingCapExceeded();
        }

        _updatePool();
        _updateUser(msg.sender);

        stakingToken.safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        UserInfo storage user =
            users[msg.sender];

        user.amount += amount;

        totalStaked += amount;

        uint256 poolLength =
            rewardPools.length;

        for (uint256 i; i < poolLength;) {

            user.rewardDebt[i] =
                (user.amount *
                    rewardPools[i]
                        .accRewardPerShare)
                    / PRECISION;

            unchecked {
                ++i;
            }
        }

        emit Staked(msg.sender, amount);
    }

    // =============================================================
    //                         WITHDRAW
    // =============================================================

    function withdraw(
        uint256 amount
    )
        public
        nonReentrant
        whenNotPaused
    {

        if (amount == 0)
            revert InvalidAmount();

        UserInfo storage user =
            users[msg.sender];

        if (user.amount < amount)
            revert InsufficientStake();

        if (
            locked &&
            block.timestamp < endTime
        ) {
            revert PoolStillRunning();
        }

        _updatePool();
        _updateUser(msg.sender);

        user.amount -= amount;

        totalStaked -= amount;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        uint256 poolLength =
            rewardPools.length;

        for (uint256 i; i < poolLength;) {

            user.rewardDebt[i] =
                (user.amount *
                    rewardPools[i]
                        .accRewardPerShare)
                    / PRECISION;

            unchecked {
                ++i;
            }
        }

        emit Withdrawn(msg.sender, amount);
    }

    // =============================================================
    //                           CLAIM
    // =============================================================

    function claimAll()
        public
        nonReentrant
        whenNotPaused
    {

        _updatePool();
        _updateUser(msg.sender);

        UserInfo storage user =
            users[msg.sender];

        uint256 poolLength =
            rewardPools.length;

        bool claimed;

        for (uint256 i; i < poolLength;) {

            uint256 reward =
                user.pendingRewards[i];

            if (reward > 0) {

                user.pendingRewards[i] = 0;

                RewardPool storage pool =
                    rewardPools[i];

                pool.distributedRewards += reward;

                pool.token.safeTransfer(
                    msg.sender,
                    reward
                );

                emit RewardClaimed(
                    msg.sender,
                    address(pool.token),
                    reward
                );

                claimed = true;
            }

            unchecked {
                ++i;
            }
        }

        if (!claimed)
            revert NothingToClaim();
    }

    // =============================================================
    //                             EXIT
    // =============================================================

    function exit()
        external
    {
        claimAll();

        withdraw(
            users[msg.sender].amount
        );
    }

    // =============================================================
    //                     VIEW FUNCTIONS
    // =============================================================

    function pendingRewards(
        address account
    )
        external
        view
        returns (uint256[] memory rewardsOut)
    {

        UserInfo storage user =
            users[account];

        uint256 poolLength =
            rewardPools.length;

        rewardsOut =
            new uint256[](poolLength);

        for (uint256 i; i < poolLength;) {

            RewardPool storage pool =
                rewardPools[i];

            uint256 accRewardPerShare =
                pool.accRewardPerShare;

            if (
                block.timestamp >
                    pool.lastUpdateTime &&
                totalStaked > 0
            ) {

                uint256 elapsed =
                    _lastApplicableTime() -
                    pool.lastUpdateTime;

                uint256 reward =
                    elapsed *
                    pool.rewardRate;

                accRewardPerShare +=
                    (reward * PRECISION)
                    / totalStaked;
            }

            uint256 accumulated =
                (user.amount *
                    accRewardPerShare)
                    / PRECISION;

            rewardsOut[i] =
                user.pendingRewards[i] +
                (
                    accumulated -
                    user.rewardDebt[i]
                );

            unchecked {
                ++i;
            }
        }
    }

    function rewardPoolLength()
        external
        view
        returns (uint256)
    {
        return rewardPools.length;
    }

    function stakedBalance(
        address account
    )
        external
        view
        returns (uint256)
    {
        return users[account].amount;
    }

    // =============================================================
    //                        ADMIN FUNCTIONS
    // =============================================================

    function pause()
        external
        onlyOwner
    {
        _pause();
    }

    function unpause()
        external
        onlyOwner
    {
        _unpause();
    }

    function cancelPool()
        external
        onlyOwner
    {

        if (block.timestamp >= startTime)
            revert PoolAlreadyStarted();

        canceled = true;

        emit PoolCanceled();
    }

    function recoverUnassignedRewards(
        uint256 poolId
    )
        external
        onlyOwner
        nonReentrant
    {

        RewardPool storage pool =
            rewardPools[poolId];

        uint256 remaining =
            pool.totalRewards -
            pool.distributedRewards;

        if (remaining == 0)
            revert NothingToClaim();

        pool.distributedRewards += remaining;

        pool.token.safeTransfer(
            owner(),
            remaining
        );

        emit RewardsRecovered(
            address(pool.token),
            remaining
        );
    }

    function emergencyRecoverToken(
        address token,
        uint256 amount
    )
        external
        onlyOwner
    {

        if (token == address(stakingToken))
            revert InvalidAddress();

        IERC20(token).safeTransfer(
            owner(),
            amount
        );
    }

    // =============================================================
    //                    EMERGENCY WITHDRAW
    // =============================================================

    function emergencyWithdraw()
        external
        nonReentrant
    {

        UserInfo storage user =
            users[msg.sender];

        uint256 amount =
            user.amount;

        if (amount == 0)
            revert InvalidAmount();

        user.amount = 0;

        totalStaked -= amount;

        stakingToken.safeTransfer(
            msg.sender,
            amount
        );

        emit EmergencyWithdraw(
            msg.sender,
            amount
        );
    }
}
