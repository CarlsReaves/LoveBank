// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/IGasStake.sol";
import "./interface/DoubleEndedQueueAddress.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

interface IRandom {
    function finalDays(uint256 k, bool first)
        external
        view
        returns (uint256 days_);

    function withdrawDays(uint256 k, uint8 level)
        external
        view
        returns (uint256 days_);
}

interface IAccount {
    function add(address addr, address parent) external;

    function upgrade(
        address addr,
        uint8 target,
        uint256 depositTotal
    ) external;

    function info(address addr)
        external
        view
        returns (
            address parent,
            uint8 level,
            uint256 id
        );

    function follows(address addr) external view returns (address[] memory);

    function parent(address addr) external view returns (address);

    function level(address addr) external view returns (uint8);
}

contract LoveBank is ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using DoubleEndedQueue for DoubleEndedQueue.AddressDeque;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint32[] versions;
    uint32 versionTimes;

    uint32 constant interval = 60 * 60;
    address usdt = address(0);
    address gas = address(0);
    address collect = address(0);
    address gasStake = address(0);

    function init(
        address _usdt,
        address _gas,
        address _collect,
        address _gasStake,
        address _random,
        address _account
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        usdt = _usdt;
        gas = _gas;
        collect = _collect;
        gasStake = _gasStake;
        iAccount = IAccount(_account);
        iRandom = IRandom(_random);
    }

    IRandom private iRandom;
    IAccount private iAccount;

    uint256 public depositTotal;
    uint256 public preTotal;
    uint256 public withdrawTotal;
    uint256 public collectTotal;

    uint8[] public bonusPercent = [0, 7, 10, 13, 15, 18];
    uint8 public topBonusPercent = 1;
    uint8 public baseRate = 15;

    uint256[] public depositEach = [
        1000e18,
        1000e18,
        3000e18,
        5000e18,
        7000e18,
        10000e18
    ];
    uint32[] public depositInterval = [
        7 * interval,
        7 * interval,
        5 * interval,
        3 * interval,
        2 * interval,
        1 * interval
    ];

    struct Broker {
        uint32 currentVersionTimestamp;
        uint256 depositTotal;
        uint256 depositCurrent;
        uint256 bonusCalc;
        uint256 bonusMax;
        uint256 bonusWithrawed;
        uint256 punishTimes;
        int256 profitAmount;
    }

    mapping(address => Broker) public brokers;
    mapping(address => uint256) public bonusDrawables;
    mapping(uint32 => uint256) public depositAmountDays;

    struct Deposit {
        uint256 amount;
        uint256 preAmount;
        uint256 finalAmount;
        uint256 withdrawAmount;
        uint8 ratePercent;
        uint32 createTimestamp;
        uint32 startFinalPayTimestamp;
        uint32 endFinalPayTimestamp;
        uint32 drawableTimestamp;
        uint8 status;
    }

    mapping(address => Deposit[]) public deposits;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(OPERATOR_ROLE, _msgSender());
        iAccount = IAccount(address(0));
        iRandom = IRandom(address(0));
        versions.push(uint32(block.timestamp));
        versionTimes = 0;
    }

    function setDepositInterval(uint8 _index, uint32 _interval)
        external
        onlyRole(OPERATOR_ROLE)
    {
        depositInterval[_index] = _interval;
    }

    function setBrokerMaxDepositAmountEach(uint8 _index, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
    {
        depositEach[_index] = amount;
    }

    function versionTimeList() external view returns (uint32[] memory) {
        return versions;
    }

    function active(address parent) external {
        accountAdd(msg.sender, parent);
    }

    function invite(address addr) external {
        accountAdd(addr, msg.sender);
    }

    function accountAdd(address addr, address parent) private {
        require(!restartStatus, "system on restart status");
        iAccount.add(addr, parent);
        IERC20(gas).safeTransferFrom(msg.sender, collect, 1e18);
        collectTotal += 1e18;
        brokers[addr].currentVersionTimestamp = versions[versionTimes];
    }

    function upgrade(uint8 target) external {
        iAccount.upgrade(msg.sender, target, brokers[msg.sender].depositTotal);
    }

    function accountInfo(address addr)
        external
        view
        returns (
            address parent,
            uint8 level,
            uint256 id
        )
    {
        (parent, level, id) = iAccount.info(addr);
    }

    function followList(address addr)
        external
        view
        returns (address[] memory addrs, uint256[] memory levels)
    {
        addrs = iAccount.follows(addr);
        levels = new uint256[](addrs.length);
        for (uint256 i = 0; i < addrs.length; i++) {
            (, levels[i], ) = iAccount.info(addr);
        }
    }

    function preDeposit(uint256 amount, bool useCommentReward)
        external
        nonReentrant
    {
        _lossClaim(msg.sender);
        require(amount >= 100e18, "LoveBank: amount must greater than 100.");
        require(amount % 1e18 == 0, "LoveBank: amount must be an integer.");
        require(!restartStatus, "LoveBank: system on restart.");
        require(
            depositRemainToday() > 0,
            "LoveBank: insufficient remain today."
        );
        require(
            !useCommentReward || commentTimes[msg.sender] > 0,
            "LoveBank: not commentReward."
        );
        (, uint8 level, uint256 id) = iAccount.info(msg.sender);
        require(id != 0, "LoveBank: account have not active.");
        require(
            amount <= depositEach[level],
            "LoveBank: amount limit of your level."
        );
        require(
            deposits[msg.sender].length == 0 ||
                block.timestamp -
                    deposits[msg.sender][deposits[msg.sender].length - 1]
                        .createTimestamp >=
                depositInterval[level],
            "LoveBank: deposit interval limit of your level."
        );
        require(!checkBlacklist(msg.sender), "LoveBank: you are in blacklist");
        uint256 preAmount = amount / 10;
        IERC20(usdt).safeTransferFrom(msg.sender, address(this), preAmount);
        Deposit storage deposit = deposits[msg.sender].push();
        deposit.amount = amount;
        deposit.preAmount = preAmount;
        deposit.finalAmount = amount - preAmount;
        deposit.ratePercent = baseRate;
        if (useCommentReward) {
            commentTimes[msg.sender] -= 1;
            deposit.ratePercent += commentRate;
        }
        deposit.withdrawAmount = amount + (amount * deposit.ratePercent) / 100;
        deposit.createTimestamp = uint32(block.timestamp);

        uint256 days_ = iRandom.finalDays(
            depositWithdrawRatePercent(),
            brokers[msg.sender].depositTotal == 0
        );
        deposit.startFinalPayTimestamp = uint32(
            block.timestamp + days_ * interval
        );

        deposit.endFinalPayTimestamp = uint32(
            block.timestamp + (days_ + 2) * interval
        );
        deposit.status = 10;

        preTotal += deposit.finalAmount;
        brokers[msg.sender].depositTotal += preAmount;
        brokers[msg.sender].depositCurrent += preAmount;
        brokers[msg.sender].bonusMax += preAmount * 3;
        brokers[msg.sender].profitAmount -= int256(preAmount);
        depositAmountDays[today()] += preAmount;
        allocAmount(preAmount);
    }

    function finalDeposit(uint256 _index) external nonReentrant {
        _lossClaim(msg.sender);
        require(!restartStatus, "LoveBank: system on restart status");
        Deposit storage deposit = deposits[msg.sender][_index];
        require(deposit.status == 10, "LoveBank: deposit status error.");
        require(
            block.timestamp >= deposit.startFinalPayTimestamp,
            "LoveBank: deposit not allow final pay."
        );
        require(
            block.timestamp < deposit.endFinalPayTimestamp,
            "LoveBank: deposit is overtime."
        );

        uint256 finalAmount = deposit.finalAmount;
        IERC20(usdt).safeTransferFrom(msg.sender, address(this), finalAmount);
        deposit.status = 20;

        uint256 days_ = iRandom.withdrawDays(
            depositWithdrawRatePercent(),
            iAccount.level(msg.sender)
        );
        deposit.drawableTimestamp = uint32(block.timestamp + days_ * interval);
        preTotal -= finalAmount;
        withdrawTotal += deposit.withdrawAmount;
        brokers[msg.sender].depositTotal += finalAmount;
        brokers[msg.sender].depositCurrent += finalAmount;
        brokers[msg.sender].bonusMax += finalAmount * 3;
        brokers[msg.sender].profitAmount -= int256(finalAmount);
        depositAmountDays[today()] += finalAmount;
        allocAmount(finalAmount);
    }

    function withdraw(uint256 _index) external nonReentrant {
        _lossClaim(msg.sender);
        require(!restartStatus, "LoveBank: system on restart status");
        require(!checkBlacklist(msg.sender), "LoveBank: you are in blacklist");
        Deposit memory deposit = deposits[msg.sender][_index];
        require(
            deposit.status == 20 || deposit.status == 50,
            "LoveBank: deposit can`t withdraw"
        );
        require(
            deposit.drawableTimestamp <= block.timestamp,
            "LoveBank: withdraw time have not yet."
        );
        uint256 fuelAmount = deposit.withdrawAmount / 100;
        withdrawTotal -= deposit.withdrawAmount;
        depositTotal -= deposit.withdrawAmount;
        brokers[msg.sender].depositCurrent -= deposit.amount;
        brokers[msg.sender].profitAmount += int256(deposit.withdrawAmount);
        if (deposit.status == 50) {
            restartSubmitTimes -= 1;
        }
        deposits[msg.sender][_index].status = 30;
        commentSubmitTimes[msg.sender] += 1;
        IERC20(gas).safeTransferFrom(msg.sender, collect, fuelAmount);
        collectTotal += fuelAmount;
        IERC20(usdt).safeTransfer(msg.sender, deposit.withdrawAmount);
    }

    function allocAmount(uint256 amount) private {
        uint256 brokerAmount = (amount * 19) / 100;
        sprintBalance += (amount * 4) / 1000;
        restartBalance += (amount * 5) / 1000;
        depositTotal += (amount * 795) / 1000;
        processBonus(msg.sender, brokerAmount);
        processFomo(msg.sender);
        fomoBalance += (amount * 1) / 1000;
        processSprint(msg.sender);
        IERC20(usdt).safeIncreaseAllowance(gasStake, (amount * 5) / 1000);
        IGasStake(gasStake).recharge((amount * 5) / 1000);
    }

    function processBonus(address addr, uint256 amount) private {
        uint8 level = 0;
        uint256 _amount = amount;
        for (uint256 i = 0; i < 30; i++) {
            address parent = iAccount.parent(addr);
            if (parent == address(0)) {
                break;
            }
            uint8 parentLevel = iAccount.level(parent);
            if (parentLevel == level && level == 5) {
                uint256 bonus = verifyBonus(parent, _amount, topBonusPercent);
                amount -= bonus;
                break;
            } else if (bonusPercent[parentLevel] > bonusPercent[level]) {
                uint8 diffPercent = bonusPercent[parentLevel] -
                    bonusPercent[level];
                uint256 bonus = verifyBonus(parent, _amount, diffPercent);
                amount -= bonus;
                level = parentLevel;
            }
            addr = parent;
        }
        if (amount > 0) {
            depositTotal += amount;
        }
    }

    function verifyBonus(
        address addr,
        uint256 amount,
        uint8 _bonusPercent
    ) private returns (uint256) {
        if (versions[versionTimes] != brokers[addr].currentVersionTimestamp) {
            return 0;
        }
        if (brokers[addr].depositCurrent < amount) {
            amount = brokers[addr].depositCurrent;
        }
        uint256 bonus = (amount * _bonusPercent) / 19;
        brokers[addr].bonusCalc += bonus;
        return bonus;
    }

    function bonusWithdraw() external nonReentrant {
        require(
            brokers[msg.sender].depositCurrent > 0,
            "you current deposit is empty."
        );
        uint256 amount = bonusDrawable(msg.sender);
        if (amount > 0) {
            brokers[msg.sender].bonusMax -= amount;
            brokers[msg.sender].bonusWithrawed += amount;
            brokers[msg.sender].profitAmount += int256(amount);
        }
        if (bonusDrawables[msg.sender] > 0) {
            amount += bonusDrawables[msg.sender];
            bonusDrawables[msg.sender] = 0;
        }
        if (amount > 0) {
            IERC20(gas).safeTransferFrom(msg.sender, collect, amount / 100);
            collectTotal += amount / 100;
            IERC20(usdt).safeTransfer(msg.sender, amount);
        }
    }

    function bonusDrawable(address addr) public view returns (uint256 amount) {
        if (
            brokers[addr].bonusMax > 0 &&
            brokers[addr].bonusCalc > brokers[addr].bonusWithrawed
        ) {
            amount = brokers[addr].bonusCalc - brokers[addr].bonusWithrawed;
            if (amount > brokers[addr].bonusMax) {
                amount = brokers[addr].bonusMax;
            }
        }
    }

    function checkBlacklist(address addr) public view returns (bool result) {
        Deposit[] storage deposits_ = deposits[addr];
        for (uint256 i = 0; i < deposits_.length; i++) {
            if (
                deposits_[i].status == 10 &&
                block.timestamp > deposits_[i].endFinalPayTimestamp
            ) {
                return true;
            }
        }
    }

    function dealBlacklist(uint256 index) external nonReentrant {
        Deposit storage deposit = deposits[msg.sender][index];
        require(deposit.status == 10, "deposit status error.");
        require(
            block.timestamp > deposit.endFinalPayTimestamp,
            "deposit have no overtime"
        );
        brokers[msg.sender].punishTimes += 1;
        require(
            block.timestamp >=
                deposit.endFinalPayTimestamp +
                    7 *
                    interval *
                    brokers[msg.sender].punishTimes,
            "deposit in punish time"
        );
        deposit.status = 40;
        IERC20(gas).transferFrom(
            msg.sender,
            address(this),
            100e18 * brokers[msg.sender].punishTimes
        );
        collectTotal += 100e18 * brokers[msg.sender].punishTimes;
    }

    function depositList(address addr)
        external
        view
        returns (Deposit[] memory)
    {
        return deposits[addr];
    }

    function depositWithdrawRatePercent() private view returns (uint256) {
        if (withdrawTotal != 0) {
            return ((depositTotal + preTotal) * 100) / withdrawTotal;
        } else {
            return 100;
        }
    }

    uint256 public fomoStartMinBalance;
    uint256 public fomoCalcMinAmount;
    uint256 public fomoWaitingSeconds;

    uint256 public fomoBalance;
    address public fomoCurrentAccount;
    uint256 public fomoEndTimestamp;
    mapping(address => uint256) public fomoRewardDrawables;

    function fomoInit(
        uint256 startMinBalance,
        uint256 calcMinAmount,
        uint256 waitingSeconds
    ) external onlyRole(OPERATOR_ROLE) {
        fomoStartMinBalance = startMinBalance;
        fomoCalcMinAmount = calcMinAmount;
        fomoWaitingSeconds = waitingSeconds;
    }

    function processFomo(address addr) private {
        if (
            fomoBalance >= fomoStartMinBalance &&
            block.timestamp >= fomoEndTimestamp
        ) {
            fomoRewardDrawables[fomoCurrentAccount] += fomoBalance;
            fomoBalance = 0;
        }
        if (brokers[addr].depositTotal >= fomoCalcMinAmount) {
            fomoCurrentAccount = addr;
            fomoEndTimestamp = block.timestamp + fomoWaitingSeconds;
        }
    }

    function fomoWithdraw() external nonReentrant {
        require(!checkBlacklist(msg.sender), "LoveBank: you are in blacklist.");
        require(
            fomoRewardDrawables[msg.sender] > 0,
            "LoveBank: insufficient of fomo drawable."
        );
        IERC20(gas).safeTransferFrom(
            msg.sender,
            collect,
            fomoRewardDrawables[msg.sender] / 100
        );
        collectTotal += fomoRewardDrawables[msg.sender] / 100;
        IERC20(usdt).safeTransfer(msg.sender, fomoRewardDrawables[msg.sender]);
        brokers[msg.sender].profitAmount += int256(
            fomoRewardDrawables[msg.sender]
        );
        fomoRewardDrawables[msg.sender] = 0;
    }

    uint256 public sprintMin;
    uint256 public sprintBalance;
    DoubleEndedQueue.AddressDeque private last100Accounts;
    mapping(address => bool) private isLast100Accounts;
    mapping(address => uint256) public sprintDrawables;

    function last100AccountList() external view returns (address[] memory) {
        address[] memory last100AccountList_ = new address[](
            last100Accounts.length()
        );
        for (uint256 i = 0; i < last100Accounts.length(); i++) {
            last100AccountList_[i] = last100Accounts.at(i);
        }
        return last100AccountList_;
    }

    function sprintInit(uint256 _sprintMin) external onlyRole(OPERATOR_ROLE) {
        sprintMin = _sprintMin;
    }

    function processSprint(address addr) private {
        if (brokers[addr].depositTotal >= sprintMin) {
            if (!isLast100Accounts[addr]) {
                last100Accounts.pushBack(addr);
                isLast100Accounts[addr] = true;
            }
            if (last100Accounts.length() > 100) {
                delete isLast100Accounts[last100Accounts.popFront()];
            }
        }
    }

    function sprintWithdraw() external nonReentrant {
        require(!checkBlacklist(msg.sender), "LoveBank: you are in blacklist.");
        require(
            sprintDrawables[msg.sender] > 0,
            "LoveBank: insufficient of sprint drawable."
        );
        IERC20(gas).safeTransferFrom(
            msg.sender,
            collect,
            sprintDrawables[msg.sender] / 100
        );
        collectTotal += sprintDrawables[msg.sender] / 100;
        IERC20(usdt).safeTransfer(msg.sender, sprintDrawables[msg.sender]);
        sprintDrawables[msg.sender] = 0;
    }

    uint8 commentRate = 3;
    mapping(address => uint256) public commentSubmitTimes;
    mapping(address => uint256) public commentTimes;
    string[] comments;

    function commentSubmit(string calldata comment) external {
        require(commentSubmitTimes[msg.sender] > 0, "You can`t commit.");
        comments.push(comment);
        commentSubmitTimes[msg.sender] -= 1;
        commentTimes[msg.sender] += 1;
    }

    function commentLength() external view returns (uint256) {
        return comments.length;
    }

    function commentList(uint32 offset, uint32 size)
        external
        view
        returns (string[] memory results, uint256 total)
    {
        total = comments.length;
        if (offset + size <= total) {
            results = new string[](size);
            for (uint256 i = 0; i < size; i++) {
                results[i] = comments[i + offset];
            }
        }
    }

    uint256 public restartBalance;
    uint256 public restartTimes = 0;
    bool public restartStatus;
    uint256 public restartSubmitTimes;
    uint256 public restartUntil;

    struct Loss {
        uint256 amount;
        uint256 drawedAmount;
        uint32 withdrawEndTimestamp;
        uint32 lastWithdrawTimestamp;
    }
    mapping(address => mapping(uint32 => Loss)) public losses;

    function restart(uint256 depositIndex) external {
        require(
            deposits[msg.sender][depositIndex].status == 20,
            "LoveBank: deposit status error."
        );
        require(
            block.timestamp >
                deposits[msg.sender][depositIndex].createTimestamp +
                    2 *
                    interval,
            "LoveBank: this deposit not satisfy to restart."
        );
        require(
            withdrawTotal / depositTotal > 10,
            "LoveBank: bank no need to restart."
        );
        restartSubmitTimes += 1;
        if (restartSubmitTimes > 3) {
            restartStatus = true;
            restartUntil = block.timestamp + 2 * interval;
            uint256 sprintBalanceEach = sprintBalance /
                last100Accounts.length();
            for (uint256 i = 0; i < last100Accounts.length(); i++) {
                sprintDrawables[last100Accounts.at(i)] += sprintBalanceEach;
                brokers[last100Accounts.at(i)].profitAmount += int256(
                    sprintBalanceEach
                );
            }
            sprintBalance = 0;
            last100Accounts.clear();
            restartSubmitTimes = 0;
        }
        deposits[msg.sender][depositIndex].status = 50;
    }

    function start() external {
        require(restartStatus, "LoveBank: not in restart status.");
        require(block.timestamp > restartUntil, "LoveBank: in restart time.");
        restartStatus = false;
        versions.push(uint32(block.timestamp));
        versionTimes += 1;
        depositTotal += restartBalance;
        delete restartBalance;
        delete preTotal;
        delete withdrawTotal;
        delete fomoBalance;
        delete collectTotal;
    }

    function lossClaim() external {
        _lossClaim(msg.sender);
    }

    function _lossClaim(address addr) private {
        if (versions[versionTimes] != brokers[addr].currentVersionTimestamp) {
            if (brokers[addr].profitAmount < 0) {
                Loss storage lossCompensation = losses[addr][
                    brokers[addr].currentVersionTimestamp
                ];
                lossCompensation.withdrawEndTimestamp = uint32(
                    block.timestamp + 2000 * interval
                );
                lossCompensation.lastWithdrawTimestamp = uint32(
                    block.timestamp
                );
                lossCompensation.amount = uint256(-brokers[addr].profitAmount);
            }
            uint256 amount = bonusDrawable(addr);
            if (amount > 0) {
                bonusDrawables[addr] += amount;
            }
            delete brokers[addr];
            delete deposits[addr];
            delete commentSubmitTimes[addr];
            delete commentTimes[addr];
            delete isLast100Accounts[addr];
            brokers[addr].currentVersionTimestamp = versions[versionTimes];
        }
    }

    function lossWithdraw(uint32 _version) external nonReentrant {
        uint256 drawable = lossPending(msg.sender, _version);
        require(drawable > 0, "Insufficient of lossCompensation");
        IERC20(gas).safeTransfer(msg.sender, drawable);
        losses[msg.sender][_version].drawedAmount += drawable;
        losses[msg.sender][_version].lastWithdrawTimestamp = uint32(
            block.timestamp - (block.timestamp % interval)
        );
    }

    function lossPending(address addr, uint32 _version)
        public
        view
        returns (uint256 drawable)
    {
        Loss storage loss = losses[addr][_version];
        if (loss.amount != 0) {
            uint256 remainSecond = block.timestamp - loss.lastWithdrawTimestamp;
            if (loss.withdrawEndTimestamp < block.timestamp) {
                remainSecond =
                    loss.withdrawEndTimestamp -
                    loss.lastWithdrawTimestamp;
            }
            uint256 remainDays = remainSecond / interval;
            drawable = (remainDays * loss.amount) / 2000;
        }
    }

    function depositRemainToday() public view returns (uint256) {
        uint32 days_ = ((uint32(block.timestamp) - versions[versionTimes])) /
            interval;
        if (days_ > 20) {
            days_ = 20;
        }
        return
            (20_0000e18 * 141**days_) /
            (100**days_) -
            depositAmountDays[today()];
    }

    function today() public view returns (uint32) {
        return uint32(block.timestamp - (block.timestamp % (24 * 60 * 60)));
    }
}
