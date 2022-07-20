// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/IGas.sol";
import "./interface/ILpStake.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract GasSwap is AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant baseNum = 1e18;
    uint256 public swapBase = 1;

    constructor() {
        swapRatio = 1 * 1e18;
        _grantRole(OPERATOR_ROLE, _msgSender());
    }

    address public gas = address(0);
    address public usdt = address(0);
    address public lpStake = address(0);
    uint256 public swapRatio;

    function init(
        address _gas,
        address _usdt,
        address _lpStake
    ) external onlyRole(OPERATOR_ROLE) {
        gas = _gas;
        usdt = _usdt;
        lpStake = _lpStake;
    }

    function swap(uint256 _amount) external {
        require(
            _amount % (swapBase * baseNum) == 0,
            "GasSwap: incorrect amount."
        );
        uint256 usdtAmount = (_amount * swapRatio) / baseNum;
        IERC20(usdt).approve(lpStake, usdtAmount);
        IERC20(usdt).transferFrom(msg.sender, address(this), usdtAmount);
        ILpStake(lpStake).recharge(usdtAmount);
        IGas(gas).mint(msg.sender, _amount);
    }

    function setSwapBase(uint256 _swapBase) external onlyRole(OPERATOR_ROLE) {
        swapBase = _swapBase;
    }

    function setSwapRatio(uint256 _swapRatio) external onlyRole(OPERATOR_ROLE) {
        swapRatio = _swapRatio;
    }
}
