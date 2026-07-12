// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { IERC20, ISurplusPool } from "../interfaces/IVelora.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title SurplusPool
/// @notice Custody for vault collateral remaining after terminal settlement.
contract SurplusPool is ProtocolAccess, ISurplusPool {
    using SafeTransferLib for IERC20;

    bytes32 public constant ACCOUNTING_ROLE = keccak256("ACCOUNTING_ROLE");

    mapping(address account => mapping(address token => uint256 amount)) public surplusOf;
    mapping(address token => uint256 amount) public totalAccounted;
    uint256 private _entered = 1;

    error SurplusZeroAddress();
    error SurplusReentrantCall();
    error SurplusAmountZero();
    error SurplusInsufficientBalance(address token, uint256 expected, uint256 balance);
    error SurplusInsufficientClaim(uint256 available, uint256 requested);

    event SurplusAccounted(address indexed account, address indexed token, uint256 amount);
    event SurplusClaimed(
        address indexed account, address indexed token, address indexed receiver, uint256 amount
    );
    event ExcessSwept(address indexed token, address indexed receiver, uint256 amount);

    modifier nonReentrant() {
        if (_entered != 1) revert SurplusReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    constructor(address initialAdmin) ProtocolAccess(initialAdmin) { }

    /// @notice Credits collateral already transferred into this pool.
    function accountSurplus(address account, address token, uint256 amount)
        external
        override
        onlyRole(ACCOUNTING_ROLE)
    {
        if (account == address(0) || token == address(0)) revert SurplusZeroAddress();
        if (amount == 0) revert SurplusAmountZero();
        uint256 expected = totalAccounted[token] + amount;
        uint256 balance = IERC20(token).safeBalanceOf(address(this));
        if (balance < expected) revert SurplusInsufficientBalance(token, expected, balance);

        totalAccounted[token] = expected;
        surplusOf[account][token] += amount;
        emit SurplusAccounted(account, token, amount);
    }

    function claim(address token, uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 claimed)
    {
        if (receiver == address(0)) revert SurplusZeroAddress();
        uint256 available = surplusOf[msg.sender][token];
        claimed = amount == type(uint256).max ? available : amount;
        if (claimed == 0) revert SurplusAmountZero();
        if (claimed > available) revert SurplusInsufficientClaim(available, claimed);

        surplusOf[msg.sender][token] = available - claimed;
        totalAccounted[token] -= claimed;
        IERC20(token).safeTransfer(receiver, claimed);
        emit SurplusClaimed(msg.sender, token, receiver, claimed);
    }

    /// @notice Recovers tokens that were transferred without an accounting instruction.
    function sweepExcess(address token, address receiver)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        if (receiver == address(0)) revert SurplusZeroAddress();
        uint256 balance = IERC20(token).safeBalanceOf(address(this));
        uint256 accounted = totalAccounted[token];
        if (balance <= accounted) revert SurplusAmountZero();
        amount = balance - accounted;
        IERC20(token).safeTransfer(receiver, amount);
        emit ExcessSwept(token, receiver, amount);
    }
}
