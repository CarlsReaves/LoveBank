// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/IGas.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract GasStake is ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public swapRatio = 8 * 1e17;

    address public gas = address(0);
    address public usdt = address(0);
    uint256 public bonusRatio = 3;
    uint256 public bonusInterval = 5 * 60;
    uint256 public nextBonusTime = 0;

    constructor() {
        _grantRole(OPERATOR_ROLE, _msgSender());
    }

    struct UserInfo {
        uint256 amount;
        uint256 debt;
        uint256 valid;
        uint256 enableBurnAmount;
        uint256 burnedAmount;
        uint256 totalReward;
        uint256 availableReward;
    }

    mapping(address => UserInfo) public userInfoList;

    uint256 public accAwardPerShare;
    uint256 public totalStakeAmount;
    uint256 public totalBonusAmount;
    uint256 public totalBonusUsedAmount;

    function recharge(uint256 _amount) external {
        require(_amount > 0, "GasStake: incorrect amount.");
        IERC20(usdt).transferFrom(msg.sender, address(this), _amount);
        totalBonusAmount += _amount;
    }

    function award() external {
        require(totalStakeAmount != 0, "GasStake: can not award.");
        require(block.timestamp >= nextBonusTime, "GasStake: already award.");
        nextBonusTime = block.timestamp + bonusInterval;
        uint256 bonusAmount = ((totalBonusAmount - totalBonusUsedAmount) *
            bonusRatio) / 1000;
        totalBonusUsedAmount += bonusAmount;
        accAwardPerShare += (bonusAmount * 1e18) / totalStakeAmount;
    }

    function deposit(uint256 _amount) external nonReentrant {
        IERC20(gas).safeTransferFrom(msg.sender, address(this), _amount);
        UserInfo storage userInfo = userInfoList[msg.sender];
        userInfo.amount += _amount;
        userInfo.enableBurnAmount += _amount;
        userInfo.valid += (_amount * swapRatio) / 1e18;
        userInfo.debt += (_amount * accAwardPerShare) / 1e18;
        totalStakeAmount += _amount;
    }

    function pending(address _addr) public view returns (uint256) {
        return
            (userInfoList[_addr].amount * accAwardPerShare) /
            1e18 -
            userInfoList[_addr].debt;
    }

    //提取燃料
    function withdraw() external nonReentrant {
        require(
            userInfoList[msg.sender].amount > 0,
            "GasStake: insufficient balance."
        );
        UserInfo storage userInfo = userInfoList[msg.sender];
        uint256 amount = userInfo.amount;
        userInfo.availableReward += pending(msg.sender);
        userInfo.enableBurnAmount = 0;
        userInfo.valid = 0;
        userInfo.debt = 0;
        userInfo.amount = 0;
        totalStakeAmount -= amount;
        IERC20(gas).safeTransfer(msg.sender, amount);
    }

    //提取奖励
    function harvest() external nonReentrant {
        UserInfo storage userInfo = userInfoList[msg.sender];
        require(
            userInfo.amount > 0 &&
                userInfo.availableReward + pending(msg.sender) > 0,
            "GasStake: can not harvest."
        );
        userInfo.availableReward += pending(msg.sender);
        uint256 harvestNum = userInfo.availableReward;
        uint256 destroyNum = (harvestNum * 1e18) / swapRatio;
        if (harvestNum > userInfo.valid) {
            harvestNum = userInfo.valid;
            destroyNum = userInfo.amount;
            userInfo.debt = 0;
        }
        require(
            userInfo.amount >= destroyNum,
            "GasStake: available burn amount not enough."
        );
        userInfo.valid -= harvestNum;
        userInfo.amount -= destroyNum;
        userInfo.debt += pending(msg.sender);
        userInfo.burnedAmount += destroyNum;
        userInfo.totalReward += harvestNum;
        userInfo.availableReward -= harvestNum;
        userInfo.enableBurnAmount -= destroyNum;
        totalStakeAmount -= destroyNum;

        IERC20(usdt).safeTransfer(msg.sender, harvestNum);
        IGas(gas).burn(destroyNum);
    }

    function setGasAddress(address _gas) external onlyRole(OPERATOR_ROLE) {
        gas = _gas;
    }

    function setBonusRatio(uint256 _bonusRatio)
        external
        onlyRole(OPERATOR_ROLE)
    {
        bonusRatio = _bonusRatio;
    }

    function setSwapRatio(uint256 _swapRatio) external onlyRole(OPERATOR_ROLE) {
        swapRatio = _swapRatio;
    }
}
