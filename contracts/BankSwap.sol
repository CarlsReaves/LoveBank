// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./interface/IGas.sol";
import "./interface/IBank.sol";
import "./interface/ITreasury.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

interface IPancakePair {
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

contract BankSwap is ReentrancyGuard, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant SWAP_ROLE = keccak256("SWAP_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public gas = address(0);
    address public token = address(0);
    address public treasury = address(0);
    address public lp = address(0);

    constructor() {
        _grantRole(OPERATOR_ROLE, _msgSender());
    }

    mapping(address => mapping(uint256 => SwapInfo)) public swapInfos;

    struct SwapInfo {
        uint256 rate;
        uint256 limit;
        uint256 rateMax;
        uint256 swaped;
        bool status;
    }

    function init(
        address _gas,
        address _token,
        address _lp,
        address _treasury
    ) external onlyRole(OPERATOR_ROLE) {
        gas = _gas;
        token = _token;
        lp = _lp;
        treasury = _treasury;
    }

    function setSwapInfo(
        address _branch,
        uint256 _version,
        uint256 _rate,
        uint256 _limit,
        uint256 _rateMax,
        uint256 _swaped,
        bool _status
    ) external onlyRole(OPERATOR_ROLE) {
        SwapInfo storage swapInfo = swapInfos[_branch][_version];
        swapInfo.rate = _rate;
        swapInfo.limit = _limit;
        swapInfo.rateMax = _rateMax;
        swapInfo.swaped = _swaped;
        swapInfo.status = _status;
    }

    function swap(address bank, uint256 amount)
        external
        nonReentrant
        onlyRole(SWAP_ROLE)
    {
        uint32[] memory versionTimes = IBank(bank).versionTimeList();
        require(versionTimes.length > 0, "BankSwap: error of branch version.");

        uint256 version = versionTimes[versionTimes.length - 1];
        SwapInfo storage swapInfo = swapInfos[bank][version];
        require(swapInfo.status, "BankSwap: closed.");

        require(IBank(bank).restartStatus(), "BankSwap: not in restart.");

        uint256 gasAmount = calcGasAmount(amount, swapInfo.rate);
        require(
            (gasAmount + swapInfo.swaped) <= swapInfo.limit,
            "BankSwap: amount exceeded."
        );

        swapInfo.swaped += gasAmount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        IERC20(token).approve(treasury, amount);
        ITreasury(treasury).recharge(address(this), amount);
        IGas(gas).mint(bank, gasAmount);
    }

    function calcGasAmount(uint256 amount, uint256 rate)
        private
        view
        returns (uint256)
    {
        (uint112 reserve0, uint112 reserve1, ) = IPancakePair(lp).getReserves();
        uint256 price = (uint256(reserve1) * 1e18) / reserve0;
        return (amount * price * rate) / 1e36;
    }
}
