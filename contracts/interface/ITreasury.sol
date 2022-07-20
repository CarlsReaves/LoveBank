// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ITreasury {
    function recharge(address account, uint256 amount) external;
}