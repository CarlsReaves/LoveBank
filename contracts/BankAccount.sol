// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract BankAccount is AccessControlEnumerable {
    bytes32 public constant BANK_ROLE = keccak256("BANK_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint8[] public upgradeCount = [0, 6, 6, 6, 6, 6];
    uint256 public upgradeDeposit = 1000e18;

    struct Account {
        address parent;
        uint8 level;
        uint256 id;
        address[] follows;
    }

    mapping(address => Account) private accounts;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function setUpGradeCount(uint8 _index, uint8 count) external onlyRole(OPERATOR_ROLE) {
        upgradeCount[_index] = count;
    }

    function add(address addr, address _parent) external onlyRole(BANK_ROLE) {
        require(accounts[addr].id == 0, "BankAccount: already existed.");
        if (_parent != address(0)) {
            require(accounts[_parent].id != 0, "BankAccount: parent nonexistent.");
            accounts[addr].parent = _parent;
        }
        accounts[addr].id = createId(addr);
        accounts[_parent].follows.push(addr);
    }

    function upgrade(address addr, uint8 target, uint256 deposit) external onlyRole(BANK_ROLE) {
        require(target > accounts[addr].level, "BankAccount: already higher level.");
        if (target == 1) {
            if (deposit >= upgradeDeposit) {
                accounts[addr].level = target;
                return;
            }
        } else {
            uint256 count = 0;
            address[] storage follows_ = accounts[addr].follows;
            for (uint256 i = 0; i < follows_.length; i++) {
                if (accounts[follows_[i]].level >= (target - 1)) {
                    count += 1;
                    if (count >= upgradeCount[target]) {
                        accounts[addr].level = target;
                        return;
                    }
                }
            }
        }
        revert("BankAccount: not satisfied.");
    }

    function info(address addr) external view onlyRole(BANK_ROLE) returns (address parent_, uint8 level_, uint256 id)  {
        parent_ = accounts[addr].parent;
        level_ = accounts[addr].level;
        id = accounts[addr].id;
    }

    function follows(address addr) external view onlyRole(BANK_ROLE) returns (address[] memory) {
        return accounts[addr].follows;
    }

    function parent(address addr) external view onlyRole(BANK_ROLE) returns (address) {
        return accounts[addr].parent;
    }

    function level(address addr) external view onlyRole(BANK_ROLE) returns (uint8) {
        return accounts[addr].level;
    }

    function createId(address addr) private view returns (uint256) {
        return (uint160(addr) % (2 ** 20)) + block.timestamp * (2 ** 20);
    }
}
