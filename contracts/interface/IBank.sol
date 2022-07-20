// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IBank { 

    function restartStatus() external view returns(bool);

    function versionTimeList() external view returns (uint32[] memory);
    
}