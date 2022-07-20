// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract LpStake is ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    bool public bonusSwitch = false;
    bool public rewardWithdrawSwitch = true;

    address public gas = address(0);
    address public sbc = address(0);
    address public usdt = address(0);
    address public pair = address(0);
    address public collect = address(0);

    uint256 public startTimestamp = block.timestamp;
    uint256 public endTimestamp = block.timestamp + 30 * 24 * 3600;
    uint256 public depositInterval = 12 * 3600;
    mapping(address => uint256) public lastDepositTimestamps;

    constructor() {
        _grantRole(OPERATOR_ROLE, _msgSender());
    }

    struct UserCurrentInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 totalAward;
    }

    struct UserDepositInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 totalAward;
        uint256 lockTimestampUntil;
        bool status;
    }

    struct PoolInfo {
        uint256 allocPoint;
        uint256 lockSecond;
        uint256 lastRewardTimestamp;
        uint256 accAwardPerShare;
        uint256 totalAmount;
        bool status;
        uint256 rewardPercent;
    }

    uint256 public awardPerSecond = 0.01 * 1e18;
    uint256 public totalAllocPoint = 0;
    PoolInfo[] public poolInfos;

    function add(
        uint256 _allocPoint,
        uint256 _lockSecond,
        uint256 _rewardPercent,
        bool _status,
        bool _withUpdate
    ) external onlyRole(OPERATOR_ROLE) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardTimestamp = block.timestamp > startTimestamp
            ? block.timestamp
            : startTimestamp;
        totalAllocPoint += _allocPoint;
        poolInfos.push(
            PoolInfo({
                allocPoint: _allocPoint,
                lockSecond: _lockSecond,
                lastRewardTimestamp: lastRewardTimestamp,
                accAwardPerShare: 0,
                totalAmount: 0,
                rewardPercent: _rewardPercent,
                status: _status
            })
        );
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint256 _lockSecond,
        uint256 _rewardPercent,
        bool _status,
        bool _withUpdate
    ) external onlyRole(OPERATOR_ROLE) {
        if (_withUpdate) {
            massUpdatePools();
        }
        require(_pid < poolInfos.length, "LpStake: pool id is not exist.");
        totalAllocPoint =
            totalAllocPoint -
            poolInfos[_pid].allocPoint +
            _allocPoint;
        poolInfos[_pid].allocPoint = _allocPoint;
        poolInfos[_pid].lockSecond = _lockSecond;
        poolInfos[_pid].status = _status;
        poolInfos[_pid].rewardPercent = _rewardPercent;
    }

    function massUpdatePools() public {
        uint256 length = poolInfos.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public returns (PoolInfo memory pool) {
        pool = poolInfos[_pid];
        if (block.timestamp > pool.lastRewardTimestamp) {
            uint256 timeSeconds;
            if (pool.totalAmount > 0) {
                if (block.timestamp > endTimestamp) {
                    timeSeconds = endTimestamp - pool.lastRewardTimestamp;
                } else {
                    timeSeconds = block.timestamp - pool.lastRewardTimestamp;
                }
                uint256 reward = (timeSeconds *
                    awardPerSecond *
                    pool.allocPoint) / totalAllocPoint;
                pool.accAwardPerShare += (reward * 1e18) / pool.totalAmount;
            }
            pool.lastRewardTimestamp += timeSeconds;
            poolInfos[_pid] = pool;
        }
    }

    function allPool() external view returns (PoolInfo[] memory) {
        return poolInfos;
    }

    mapping(address => UserCurrentInfo) public userCurrentInfos;
    mapping(address => mapping(uint256 => UserDepositInfo[]))
        public userDepositInfos;
    mapping(address => uint256) public sbcWithdrawBalance;

    uint256 public accBonus;
    uint256 public totalEffectAmount;
    uint256 public totalDepositAmount;

    uint256 public totalBonusAmount;
    uint256 public totalBonusUsedAmount;
    uint256 public bonusRatio = 1;
    uint256 public bonusInterval = 5 * 60;
    uint256 public nextBonusTime = 0;
    mapping(address => uint256) public bonusWithdrawBalance;

    mapping(address => mapping(uint256 => BonusDepositInfo[]))
        public bonusDepositInfos;
    mapping(address => BonusCurrentDepositInfo) public bonusCurrentDepositInfos;

    struct BonusCurrentDepositInfo {
        uint256 amount;
        uint256 effect;
        uint256 debt;
        uint256 reward;
    }

    struct BonusDepositInfo {
        uint256 pid;
        uint256 amount;
        uint256 effect;
        bool status;
        uint256 debt;
        uint256 reward;
    }

    function deposit(uint256 _pid, uint256 _amount) external nonReentrant {
        PoolInfo memory pool = updatePool(_pid);
        uint256 effect = (pool.rewardPercent * _amount) / 1000;
        if (pool.lockSecond == 0) {
            userCurrentInfos[msg.sender].amount += _amount;
            userCurrentInfos[msg.sender].rewardDebt +=
                (_amount * poolInfos[_pid].accAwardPerShare) /
                1e18;

            bonusCurrentDepositInfos[msg.sender].amount += _amount;
            bonusCurrentDepositInfos[msg.sender].effect += effect;
            bonusCurrentDepositInfos[msg.sender].debt +=
                (effect * accBonus) /
                1e18;
        } else {
            require(
                lastDepositTimestamps[msg.sender] + depositInterval <
                    block.timestamp,
                "LpStake: operation limit."
            );
            userDepositInfos[msg.sender][_pid].push(
                UserDepositInfo({
                    amount: _amount,
                    rewardDebt: (_amount * pool.accAwardPerShare) / 1e18,
                    totalAward: 0,
                    lockTimestampUntil: block.timestamp + pool.lockSecond,
                    status: true
                })
            );
            lastDepositTimestamps[msg.sender] = block.timestamp;

            BonusDepositInfo storage bonusDepositInfo = bonusDepositInfos[
                msg.sender
            ][_pid].push();
            bonusDepositInfo.pid = _pid;
            bonusDepositInfo.amount = _amount;
            bonusDepositInfo.effect = effect;
            bonusDepositInfo.status = true;
            bonusDepositInfo.debt = (effect * accBonus) / 1e18;
        }
        totalEffectAmount += effect;
        totalDepositAmount += _amount;
        pool.totalAmount += _amount;
        IERC20(pair).safeTransferFrom(msg.sender, address(this), _amount);
        poolInfos[_pid] = pool;
    }

    function withdraw(
        uint256 _pid,
        uint256 _amount,
        uint256 _index
    ) external nonReentrant {
        PoolInfo memory pool = updatePool(_pid);
        uint256 effect = (pool.rewardPercent * _amount) / 1000;
        if (pool.lockSecond == 0) {
            uint256 accumulatedAward = (userCurrentInfos[msg.sender].amount *
                pool.accAwardPerShare) / 1e18;
            uint256 _pending = accumulatedAward -
                userCurrentInfos[msg.sender].rewardDebt;
            userCurrentInfos[msg.sender].rewardDebt =
                accumulatedAward -
                ((_amount * pool.accAwardPerShare) / 1e18);
            userCurrentInfos[msg.sender].amount -= _amount;
            userCurrentInfos[msg.sender].totalAward += _pending;

            sbcWithdrawBalance[msg.sender] += _pending;
            IERC20(pair).safeTransfer(msg.sender, _amount);

            uint256 bonusPending = (effect * accBonus) /
                1e18 -
                bonusCurrentDepositInfos[msg.sender].debt;
            bonusCurrentDepositInfos[msg.sender].reward += bonusPending;
            bonusCurrentDepositInfos[msg.sender].debt =
                ((bonusCurrentDepositInfos[msg.sender].amount - _amount) *
                    accBonus) /
                1e18;
            bonusCurrentDepositInfos[msg.sender].amount -= _amount;
            bonusCurrentDepositInfos[msg.sender].effect -= effect;
            bonusWithdrawBalance[msg.sender] += bonusPending;
        } else {
            UserDepositInfo storage depositInfo = userDepositInfos[msg.sender][
                _pid
            ][_index];
            require(depositInfo.status, "LpStake: deposit info is withdraw.");
            require(
                depositInfo.amount == _amount,
                "LpStake: need withdraw all amount of deposit."
            );
            require(depositInfo.lockTimestampUntil <= block.timestamp);

            depositInfo.status = false;
            uint256 accumulatedAward = (depositInfo.amount *
                pool.accAwardPerShare) / 1e18;
            depositInfo.totalAward = accumulatedAward - depositInfo.rewardDebt;

            sbcWithdrawBalance[msg.sender] += depositInfo.totalAward;
            IERC20(pair).safeTransfer(msg.sender, _amount);

            BonusDepositInfo storage bonusDepositInfo = bonusDepositInfos[
                msg.sender
            ][_pid][_index];
            uint256 bonusPending = pendingForBonus(msg.sender, _pid, _index);
            bonusDepositInfo.reward += bonusPending;
            bonusDepositInfo.amount = 0;
            bonusDepositInfo.debt = 0;
            bonusDepositInfo.effect = 0;
            bonusDepositInfo.status = false;
            bonusWithdrawBalance[msg.sender] += bonusPending;
        }
        pool.totalAmount = pool.totalAmount - _amount;
        poolInfos[_pid] = pool;
        totalEffectAmount -= effect;
        totalDepositAmount -= _amount;
    }

    function harvestBatch() external nonReentrant {
        require(rewardWithdrawSwitch, "LpStake: can not harvest.");
        massUpdatePools();
        PoolInfo[] memory poolInfosMemory = poolInfos;
        uint256 totalPending = 0;
        for (uint256 i = 0; i < poolInfosMemory.length; i++) {
            if (poolInfosMemory[i].lockSecond == 0) {
                uint256 accumulatedAward = (userCurrentInfos[msg.sender]
                    .amount * poolInfosMemory[i].accAwardPerShare) / 1e18;
                uint256 _pending = accumulatedAward -
                    userCurrentInfos[msg.sender].rewardDebt;
                userCurrentInfos[msg.sender].rewardDebt = accumulatedAward;
                if (_pending > 0) {
                    userCurrentInfos[msg.sender].totalAward =
                        userCurrentInfos[msg.sender].totalAward +
                        _pending;
                    totalPending += _pending;
                }
            } else {
                UserDepositInfo[]
                    storage userDepositInfosPool = userDepositInfos[msg.sender][
                        i
                    ];
                uint256 accAwardPerShare = poolInfosMemory[i].accAwardPerShare;
                for (uint256 j = 0; j < userDepositInfosPool.length; j++) {
                    if (!userDepositInfosPool[j].status) {
                        continue;
                    }
                    uint256 _pending = (userDepositInfosPool[j].amount *
                        accAwardPerShare) /
                        1e18 -
                        userDepositInfosPool[j].rewardDebt;
                    userDepositInfosPool[j].rewardDebt += _pending;
                    userDepositInfosPool[j].totalAward += _pending;
                    totalPending += _pending;
                }
            }
        }
        if (sbcWithdrawBalance[msg.sender] > 0) {
            totalPending += sbcWithdrawBalance[msg.sender];
            sbcWithdrawBalance[msg.sender] = 0;
        }
        if (totalPending > 0) {
            IERC20(sbc).transfer(msg.sender, totalPending);
        }
    }

    function pendingAll(address _addr) external view returns (uint256) {
        uint256 totalPending = 0;
        PoolInfo[] memory poolInfosMemory = poolInfos;
        for (uint256 i = 0; i < poolInfosMemory.length; i++) {
            totalPending += pending(_addr, i);
        }
        return totalPending;
    }

    function pending(address _addr, uint256 _pid)
        public
        view
        returns (uint256)
    {
        uint256 accAwardPerShare = poolInfos[_pid].accAwardPerShare;
        uint256 lpSupply = poolInfos[_pid].totalAmount;
        if (poolInfos[_pid].lockSecond == 0) {
            if (
                block.timestamp > poolInfos[_pid].lastRewardTimestamp &&
                lpSupply != 0
            ) {
                uint256 timeSeconds = (block.timestamp > endTimestamp)
                    ? endTimestamp - poolInfos[_pid].lastRewardTimestamp
                    : block.timestamp - poolInfos[_pid].lastRewardTimestamp;
                uint256 reward = (timeSeconds *
                    awardPerSecond *
                    poolInfos[_pid].allocPoint) / totalAllocPoint;
                accAwardPerShare += (reward * 1e18) / lpSupply;
            }
            return
                (userCurrentInfos[_addr].amount * accAwardPerShare) /
                1e18 -
                userCurrentInfos[_addr].rewardDebt;
        } else {
            uint256 totalPending = 0;
            UserDepositInfo[] memory userDepositInfosPool = userDepositInfos[
                _addr
            ][_pid];
            for (uint256 i = 0; i < userDepositInfosPool.length; i++) {
                totalPending += pendingDeposit(_addr, _pid, i);
            }
            return totalPending;
        }
    }

    function pendingDeposit(
        address _addr,
        uint256 _pid,
        uint256 _index
    ) public view returns (uint256) {
        UserDepositInfo storage userDepositInfo = userDepositInfos[_addr][_pid][
            _index
        ];
        if (!userDepositInfo.status) {
            return 0;
        }
        uint256 accAwardPerShare = poolInfos[_pid].accAwardPerShare;
        uint256 lpSupply = poolInfos[_pid].totalAmount;
        if (
            block.timestamp > poolInfos[_pid].lastRewardTimestamp &&
            lpSupply != 0
        ) {
            uint256 timeSeconds = block.timestamp > endTimestamp
                ? endTimestamp - poolInfos[_pid].lastRewardTimestamp
                : block.timestamp - poolInfos[_pid].lastRewardTimestamp;
            uint256 reward = (timeSeconds *
                awardPerSecond *
                poolInfos[_pid].allocPoint) / totalAllocPoint;
            accAwardPerShare += (reward * 1e18) / lpSupply;
        }
        return
            (userDepositInfo.amount * accAwardPerShare) /
            1e18 -
            userDepositInfo.rewardDebt;
    }

    function recharge(uint256 amount) external nonReentrant {
        require(amount > 0, "LpStake: incorrect amount.");
        IERC20(usdt).transferFrom(msg.sender, address(this), amount);
        totalBonusAmount += amount;
    }

    function award() external nonReentrant {
        uint256 bonusAmount = ((totalBonusAmount - totalBonusUsedAmount) *
            bonusRatio) / 100;
        require(bonusSwitch && bonusAmount > 0, "LpStake: can not award.");
        require(block.timestamp >= nextBonusTime, "LpStake: already award.");
        nextBonusTime = block.timestamp + bonusInterval;
        totalBonusUsedAmount += bonusAmount;
        accBonus += (bonusAmount * 1e18) / totalEffectAmount;
    }

    function harvestForBonus() external nonReentrant {
        PoolInfo[] memory poolInfosMemory = poolInfos;
        uint256 totalBonusPending = 0;
        for (uint256 i = 0; i < poolInfosMemory.length; i++) {
            if (poolInfosMemory[i].lockSecond == 0) {
                uint256 currentPending = (bonusCurrentDepositInfos[msg.sender]
                    .effect * accBonus) /
                    1e18 -
                    bonusCurrentDepositInfos[msg.sender].debt;
                bonusCurrentDepositInfos[msg.sender].debt += currentPending;
                bonusCurrentDepositInfos[msg.sender].reward += currentPending;
                totalBonusPending += currentPending;
            } else {
                BonusDepositInfo[]
                    storage bonusDepositInfoList = bonusDepositInfos[
                        msg.sender
                    ][i];
                for (uint256 k = 0; k < bonusDepositInfoList.length; k++) {
                    if (!bonusDepositInfoList[k].status) {
                        continue;
                    }
                    uint256 _bonusDepositPending = pendingForBonus(
                        msg.sender,
                        i,
                        k
                    );
                    bonusDepositInfoList[k].debt += _bonusDepositPending;
                    bonusDepositInfoList[k].reward += _bonusDepositPending;
                    totalBonusPending += _bonusDepositPending;
                }
            }
        }

        if (bonusWithdrawBalance[msg.sender] > 0) {
            totalBonusPending += bonusWithdrawBalance[msg.sender];
            bonusWithdrawBalance[msg.sender] = 0;
        }

        if (totalBonusPending > 0) {
            uint256 burnAmount = totalBonusPending / 100;
            IERC20(gas).transferFrom(msg.sender, collect, burnAmount);
            IERC20(usdt).safeTransfer(msg.sender, totalBonusPending);
        }
    }

    function pendingForBonus(
        address _addr,
        uint256 _pid,
        uint256 _index
    ) public view returns (uint256) {
        BonusDepositInfo storage bonusDepositInfo = bonusDepositInfos[_addr][
            _pid
        ][_index];
        return
            (bonusDepositInfo.effect * accBonus) / 1e18 - bonusDepositInfo.debt;
    }

    function pendingForAllBonus(address _addr) external view returns (uint256) {
        PoolInfo[] memory poolInfosMemory = poolInfos;
        uint256 totalBonusPending = 0;
        for (uint256 i = 0; i < poolInfosMemory.length; i++) {
            if (poolInfosMemory[i].lockSecond == 0) {
                uint256 currentPending = (bonusCurrentDepositInfos[_addr]
                    .amount * accBonus) /
                    1e18 -
                    bonusCurrentDepositInfos[_addr].debt;
                totalBonusPending += currentPending;
            } else {
                BonusDepositInfo[]
                    storage bonusDepositInfoList = bonusDepositInfos[_addr][i];
                for (uint256 k = 0; k < bonusDepositInfoList.length; k++) {
                    if (!bonusDepositInfoList[k].status) {
                        continue;
                    }
                    uint256 _bonusDepositPending = pendingForBonus(_addr, i, k);
                    totalBonusPending += _bonusDepositPending;
                }
            }
        }
        return totalBonusPending;
    }

    function pendingCurrentForBonus(address _addr)
        external
        view
        returns (uint256)
    {
        return
            (bonusCurrentDepositInfos[_addr].amount * accBonus) /
            1e18 -
            bonusCurrentDepositInfos[_addr].debt;
    }

    function queryTotalBonusEffect(address _addr)
        external
        view
        returns (uint256)
    {
        uint256 totalBonusEffect = 0;
        totalBonusEffect += bonusCurrentDepositInfos[_addr].effect;
        for (uint256 i = 0; i < poolInfos.length; i++) {
            BonusDepositInfo[] memory bonusDeposits = bonusDepositInfos[_addr][
                i
            ];
            for (uint256 k = 0; k < bonusDeposits.length; k++) {
                if (bonusDeposits[k].status) {
                    totalBonusEffect += bonusDeposits[k].effect;
                }
            }
        }
        return totalBonusEffect;
    }

    function setRewardWithdrawSwitch(bool _bool)
        external
        onlyRole(OPERATOR_ROLE)
    {
        rewardWithdrawSwitch = _bool;
    }

    function setDepositInterval(uint256 _depositInterval)
        external
        onlyRole(OPERATOR_ROLE)
    {
        depositInterval = _depositInterval;
    }

    function setSbc(address _sbc) external onlyRole(OPERATOR_ROLE) {
        sbc = _sbc;
    }

    function setPair(address _pair) external onlyRole(OPERATOR_ROLE) {
        pair = _pair;
    }

    function setStartTimestamp(uint256 _startTimestamp)
        external
        onlyRole(OPERATOR_ROLE)
    {
        startTimestamp = _startTimestamp;
    }

    function setEndTimestamp(uint256 _endTimestamp)
        external
        onlyRole(OPERATOR_ROLE)
    {
        endTimestamp = _endTimestamp;
    }

    function setBonusRate(uint256 _bonusRatio)
        external
        onlyRole(OPERATOR_ROLE)
    {
        bonusRatio = _bonusRatio;
    }

    function setAwardPerSecond(uint256 _awardPerSecond)
        external
        onlyRole(OPERATOR_ROLE)
    {
        awardPerSecond = _awardPerSecond;
    }

    function setBonusSwitch(bool _bonusSwitch)
        external
        onlyRole(OPERATOR_ROLE)
    {
        bonusSwitch = _bonusSwitch;
    }
}
