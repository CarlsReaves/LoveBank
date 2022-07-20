// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/ITreasury.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

interface IUinSwapFactory {
    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);
}

interface IUniSwapRouter {
    function factory() external pure returns (address);
}

contract Token is ERC20, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 public constant maxSupply = 1000_0000_0000 * 1e18;

    address public usdt = address(0);
    address public loan = address(0);
    address public treasury = address(0);
    address public swapRouter = address(0);
    address public pair = address(0);

    EnumerableSet.AddressSet private pairAddressSet;

    uint8 public loanRate = 3;
    uint8 public treasuryRate = 2;

    constructor() ERC20("BLC", "BLC") {
        _grantRole(OPERATOR_ROLE, _msgSender());
        super._mint(msg.sender, maxSupply);
        IUniSwapRouter uinSwapRouter = IUniSwapRouter(swapRouter);
        pair = IUinSwapFactory(uinSwapRouter.factory()).createPair(
            address(this),
            usdt
        );
        pairAddressSet.add(pair);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (pairAddressSet.contains(to)) {
            uint256 loanAmount = (amount * loanRate) / 100;
            uint256 treasuryAmount = (amount * treasuryRate) / 100;
            amount = amount - (loanAmount + treasuryAmount);
            super._transfer(from, to, amount);
            super._transfer(from, loan, loanAmount);
            super._approve(from, treasury, treasuryAmount);
            ITreasury(treasury).recharge(from, treasuryAmount);
        } else {
            super._transfer(from, to, amount);
        }
    }

    function setLoan(address _loan) external onlyRole(OPERATOR_ROLE) {
        loan = _loan;
    }

    function setTreasury(address _treasury) external onlyRole(OPERATOR_ROLE) {
        treasury = _treasury;
    }
}
