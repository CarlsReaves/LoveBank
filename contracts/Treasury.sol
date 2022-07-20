// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/IMedals.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract Treasury is ERC721Holder, ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    constructor() {
        _grantRole(OPERATOR_ROLE, _msgSender());
    }

    uint256 public acc;
    address public token = address(0);
    address public medals = address(0);
    uint256 public totalEffect;
    uint256 public bonusRate = 5;
    uint256 public bonusInterval = 5 * 60;
    uint256 public nextBonusTime = 0;
    uint256 public totalBonusAmount;
    uint256 public totalBonusUsedAmount;
    mapping(address => uint256) public withdrawBalance;

    mapping(address => UserRewardInfo) public userRewardInfos;
    mapping(address => mapping(uint256 => bool)) public depositTokenIds;
    mapping(address => EnumerableSet.UintSet) private depositRecords;
    mapping(address => mapping(uint256 => uint32)) public userMedalCount;

    struct UserRewardInfo {
        uint256 debt;
        uint256 effect;
        uint256 reward;
    }

    function deposit(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length <= 9, "Treasury: amount exceeded.");
        (uint256[] memory medalIds, uint256[] memory weights) = IMedals(medals)
            .getMedalInfos(tokenIds);
        uint256 depositEffect = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            address owner = ERC721(medals).ownerOf(tokenIds[i]);
            if (msg.sender == owner) {
                depositEffect += weights[i];
                depositTokenIds[msg.sender][tokenIds[i]] = true;
                depositRecords[msg.sender].add(tokenIds[i]);
                userMedalCount[msg.sender][medalIds[i]] += 1;
                ERC721(medals).safeTransferFrom(
                    msg.sender,
                    address(this),
                    tokenIds[i]
                );
            }
        }
        if (depositEffect > 0) {
            UserRewardInfo storage userRewardInfo = userRewardInfos[msg.sender];
            userRewardInfo.effect += depositEffect;
            userRewardInfo.debt += (depositEffect * acc) / 1e18;
            totalEffect += depositEffect;
        }
    }

    function recharge(address account, uint256 amount) external {
        require(amount > 0, "Treasury: incorrect amount.");
        IERC20(token).transferFrom(account, address(this), amount);
        totalBonusAmount += amount;
    }

    function award() external nonReentrant {
        uint256 bonusAmount = (((totalBonusAmount - totalBonusUsedAmount) /
            365) * bonusRate) / 100;
        require(bonusAmount > 0, "Treasury: can not award.");
        require(block.timestamp >= nextBonusTime, "Treasury: already award.");
        nextBonusTime = block.timestamp + bonusInterval;
        totalBonusUsedAmount += bonusAmount;
        acc += (bonusAmount * 1e18) / totalEffect;
    }

    function harvest() external nonReentrant {
        uint256 totalBonusPending = 0;
        UserRewardInfo storage userRewardInfo = userRewardInfos[msg.sender];
        uint256 _pending = (userRewardInfo.effect * acc) /
            1e18 -
            userRewardInfo.debt;
        userRewardInfo.debt += _pending;
        userRewardInfo.reward += _pending;
        totalBonusPending += _pending;

        if (withdrawBalance[msg.sender] > 0) {
            totalBonusPending += withdrawBalance[msg.sender];
            withdrawBalance[msg.sender] = 0;
        }

        if (totalBonusPending > 0) {
            IERC20(token).safeTransfer(msg.sender, totalBonusPending);
        }
    }

    function pending(address addr) external view returns (uint256) {
        return
            (userRewardInfos[addr].effect * acc) /
            1e18 -
            userRewardInfos[addr].debt;
    }

    function withdraw(uint256[] calldata tokenIds) external nonReentrant {
        require(tokenIds.length <= 9, "Treasury: amount exceeded.");
        bool isNftOwner = beforeWithdraw(msg.sender, tokenIds);
        require(isNftOwner, "Treasury: not nft owner.");
        (uint256 withdrawEffect, uint256[] memory medalIds) = calcWeight(
            tokenIds
        );

        UserRewardInfo storage userRewardInfo = userRewardInfos[msg.sender];
        uint256 _pending = (userRewardInfo.effect * acc) /
            1e18 -
            userRewardInfo.debt;
        userRewardInfo.reward += _pending;
        userRewardInfo.debt =
            ((userRewardInfo.effect - withdrawEffect) * acc) /
            1e18;
        userRewardInfo.effect -= withdrawEffect;

        withdrawBalance[msg.sender] += _pending;
        totalEffect -= withdrawEffect;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            depositTokenIds[msg.sender][tokenIds[i]] = false;
            ERC721(medals).safeTransferFrom(
                address(this),
                msg.sender,
                tokenIds[i]
            );
            userMedalCount[msg.sender][medalIds[i]] -= 1;
            depositRecords[msg.sender].remove(tokenIds[i]);
        }
    }

    function beforeWithdraw(address addr, uint256[] calldata tokenIds)
        private
        view
        returns (bool)
    {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (!depositTokenIds[addr][tokenIds[i]]) {
                return false;
            }
        }
        return true;
    }

    function calcWeight(uint256[] memory tokenIds)
        private
        returns (uint256, uint256[] memory)
    {
        uint256 totalWeight = 0;
        (uint256[] memory medalIds, uint256[] memory weights) = IMedals(medals)
            .getMedalInfos(tokenIds);
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
        }
        return (totalWeight, medalIds);
    }

    function queryListByPage(
        address addr,
        uint256 offset,
        uint256 size
    ) external view returns (uint256[] memory tokenIds) {
        uint256 totalNftAmount = depositRecords[addr].length();
        require(
            offset + size <= totalNftAmount,
            "Treasury: size out of bound."
        );
        tokenIds = new uint256[](size);
        for (uint256 i = 0; i < size; i++) {
            tokenIds[i] = depositRecords[addr].at(i + offset);
        }
    }

    function queryTotalCount(address addr) external view returns (uint256) {
        return depositRecords[addr].length();
    }

    function setBonusRate(uint256 _bonusRate) external onlyRole(OPERATOR_ROLE) {
        bonusRate = _bonusRate;
    }

    function setToken(address _token) external onlyRole(OPERATOR_ROLE) {
        token = _token;
    }

    function setMedals(address _medals) external onlyRole(OPERATOR_ROLE) {
        medals = _medals;
    }
}
