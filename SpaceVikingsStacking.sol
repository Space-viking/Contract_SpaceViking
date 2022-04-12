// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";


contract SpaceVikingsStacking is
Initializable,
OwnableUpgradeable,
ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for ERC20Upgradeable;
    //Space Vikings
    ERC20Upgradeable public rewardsToken;
    ERC20Upgradeable public stakingToken;

    uint256 private constant REWARD_INTERVAL = 365 * 24 * 60 * 60;

    uint256 public startTime;

    struct ConfiguredLock {
        uint64 time; // in milliseconds
        uint32 apy; // in basis points
    }
    ConfiguredLock[] public configuredLocks;

    struct AccountStake {
        bool active;
        uint32 apy; // in basis points
        uint64 started; // in milliseconds
        uint64 unlock; // in milliseconds
        uint64 lastUpdated; // in milliseconds

        uint256 stake;
        uint256 currentRewards;
        uint256 withdrawnRewards;
    }
    mapping(address => AccountStake[]) public allAccountStakes;

    /* ========== EVENTS ========== */

    event Staked(address indexed user, uint256 indexed stakeId, uint256 amount);
    event Withdrawn(address indexed user, uint256 indexed stakeId, uint256 amount);
    event RewardPaid(address indexed user, uint256 indexed stakeId, uint256 reward);

    /* ========== INITIALIZER ========== */

    function initialize(address _stakingToken, address _rewardsToken, uint256 _startTime)
    public
    initializer
    {
        __Ownable_init();
        __ReentrancyGuard_init();

        stakingToken = ERC20Upgradeable(_stakingToken);
        rewardsToken = ERC20Upgradeable(_rewardsToken);
        startTime = _startTime;


        configuredLocks.push(ConfiguredLock(30 days, 200));
        configuredLocks.push(ConfiguredLock(90 days, 400));
        configuredLocks.push(ConfiguredLock(183 days, 600));
        configuredLocks.push(ConfiguredLock(274 days, 800));
        configuredLocks.push(ConfiguredLock(365 days, 1000));


    }

    /* ========== STAKING FUNCTIONS ========== */

    function allConfiguredLocks() external view returns (ConfiguredLock[] memory) {
        return configuredLocks;
    }

    function accountStakes(address account, bool addEarned) external view returns (
        AccountStake[] memory stakes,
        uint256[] memory stakesEarned
    ) {
        stakes = allAccountStakes[account];

        if (addEarned) {
            stakesEarned = new uint256[](allAccountStakes[account].length);
            for (uint256 idx; idx < allAccountStakes[account].length; idx++) {
                stakesEarned[idx] = earned(account, idx);
            }
        }
    }

    function earned(address account, uint256 stakeId) public view returns (uint256) {
        if (!allAccountStakes[account][stakeId].active)
            return allAccountStakes[account][stakeId].currentRewards;

        uint256 timeUntill = block.timestamp;
        if (timeUntill > allAccountStakes[account][stakeId].unlock)
            timeUntill = allAccountStakes[account][stakeId].unlock;
        if (allAccountStakes[account][stakeId].lastUpdated >= timeUntill)
            return allAccountStakes[account][stakeId].currentRewards;

        return (((
        allAccountStakes[account][stakeId].stake *
        allAccountStakes[account][stakeId].apy *
        (timeUntill - allAccountStakes[account][stakeId].lastUpdated)
        ) / REWARD_INTERVAL) / 10000) + allAccountStakes[account][stakeId].currentRewards;
    }

    function stake(uint256 _amount, uint256 _configuredLock) external {
        require(block.timestamp >= startTime, "Staking not started");
        require(configuredLocks.length > _configuredLock, "Lock does not exist");

        allAccountStakes[_msgSender()].push(AccountStake(
                true,
                configuredLocks[_configuredLock].apy,
                uint64(block.timestamp),
                uint64(block.timestamp) + configuredLocks[_configuredLock].time,
                uint64(block.timestamp),
                _amount,
                0,
                0
            ));
        stakingToken.safeTransferFrom(_msgSender(), address(this), _amount);

        emit Staked(_msgSender(), allAccountStakes[_msgSender()].length -1, _amount);
    }

    function _updateReward(address account, uint256 stakeId) private {
        require(allAccountStakes[account].length > stakeId, "User stake does not exist");
        if (!allAccountStakes[account][stakeId].active) return;

        allAccountStakes[account][stakeId].currentRewards = earned(account, stakeId);
        allAccountStakes[account][stakeId].lastUpdated = uint64(block.timestamp);
        if (allAccountStakes[account][stakeId].lastUpdated >= allAccountStakes[account][stakeId].unlock)
            allAccountStakes[account][stakeId].active = false;
    }

    modifier updateReward(address account, uint256 stakeId) {
        _updateReward(account, stakeId);
        _;
    }

    function _withdraw(uint256 _amount, uint256 _stakeId) private updateReward(_msgSender(), _stakeId) {
        require(block.timestamp >= allAccountStakes[_msgSender()][_stakeId].unlock, "Stake not unlocked");
        allAccountStakes[_msgSender()][_stakeId].stake -= _amount;
        if (allAccountStakes[_msgSender()][_stakeId].stake == 0)
            allAccountStakes[_msgSender()][_stakeId].active = false;

        stakingToken.safeTransfer(_msgSender(), _amount);

        emit Withdrawn(_msgSender(), _stakeId, _amount);
    }

    function withdraw(uint256 _amount, uint256 _stakeId) public nonReentrant {
        _withdraw(_amount, _stakeId);
    }

    function _getReward(uint256 _stakeId) private updateReward(_msgSender(), _stakeId) {
        if (allAccountStakes[_msgSender()][_stakeId].currentRewards == 0) return;
        uint256 reward = allAccountStakes[_msgSender()][_stakeId].currentRewards;
        allAccountStakes[_msgSender()][_stakeId].currentRewards = 0;
        allAccountStakes[_msgSender()][_stakeId].withdrawnRewards += reward;

        rewardsToken.safeTransfer(_msgSender(), reward);

        emit RewardPaid(_msgSender(), _stakeId, reward);
    }

    function getReward(uint256 _stakeId) public nonReentrant {
        _getReward(_stakeId);
    }

    function exit(uint256 _stakeId) public nonReentrant {
        _getReward(_stakeId);
        _withdraw(allAccountStakes[_msgSender()][_stakeId].stake, _stakeId);
    }

    function getAllRewards() external nonReentrant {
        for (uint256 stakeId = 0; stakeId < allAccountStakes[_msgSender()].length; stakeId++) {
            _updateReward(_msgSender(), stakeId);
            _getReward(stakeId);
        }
    }

    function exitUnlocked() external nonReentrant {
        for (uint256 stakeId = 0; stakeId < allAccountStakes[_msgSender()].length; stakeId++) {
            if (allAccountStakes[_msgSender()][stakeId].stake > 0 &&
                block.timestamp >= allAccountStakes[_msgSender()][stakeId].unlock) {
                _getReward(stakeId);
                _withdraw(allAccountStakes[_msgSender()][stakeId].stake, stakeId);
            }
        }
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function updateStartTime(uint256 _startTime) external onlyOwner {
        startTime = _startTime;
    }
    function updateConfiguredLock(uint256 configuredLock, uint64 time, uint32 apy) external onlyOwner {
        configuredLocks[configuredLock] = ConfiguredLock(time, apy);
    }
    function updateConfiguredLocks(ConfiguredLock[] memory locks) external onlyOwner {
        delete configuredLocks;
        for (uint256 idx = 0; idx < locks.length; idx++) {
            configuredLocks.push(ConfiguredLock(locks[idx].time, locks[idx].apy));
        }
    }
}