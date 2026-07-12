// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "../interfaces/IVelora.sol";

/// @notice Defensive wrappers for ERC-20 implementations with optional return values.
library SafeTransferLib {
    error TokenIsNotContract(address token);
    error TransferFailed(address token, address to, uint256 amount);
    error TransferFromFailed(address token, address from, address to, uint256 amount);
    error ApprovalFailed(address token, address spender, uint256 amount);
    error BalanceQueryFailed(address token, address account);
    error AllowanceQueryFailed(address token, address owner, address spender);

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        _checkContract(token);
        if (!_callOptionalBool(token, abi.encodeCall(IERC20.transfer, (to, amount)))) {
            revert TransferFailed(address(token), to, amount);
        }
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        _checkContract(token);
        if (!_callOptionalBool(token, abi.encodeCall(IERC20.transferFrom, (from, to, amount)))) {
            revert TransferFromFailed(address(token), from, to, amount);
        }
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        _checkContract(token);
        if (!_callOptionalBool(token, abi.encodeCall(IERC20.approve, (spender, amount)))) {
            revert ApprovalFailed(address(token), spender, amount);
        }
    }

    /// @notice Sets an allowance for tokens that require resetting it to zero first.
    function forceApprove(IERC20 token, address spender, uint256 amount) internal {
        _checkContract(token);
        bytes memory approval = abi.encodeCall(IERC20.approve, (spender, amount));
        if (_callOptionalBool(token, approval)) return;

        if (!_callOptionalBool(token, abi.encodeCall(IERC20.approve, (spender, 0)))) {
            revert ApprovalFailed(address(token), spender, 0);
        }
        if (!_callOptionalBool(token, approval)) {
            revert ApprovalFailed(address(token), spender, amount);
        }
    }

    function safeBalanceOf(IERC20 token, address account) internal view returns (uint256 balance_) {
        _checkContract(token);
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeCall(IERC20.balanceOf, (account)));
        if (!success || data.length < 32) revert BalanceQueryFailed(address(token), account);
        assembly ("memory-safe") {
            balance_ := mload(add(data, 0x20))
        }
    }

    function safeAllowance(IERC20 token, address owner, address spender)
        internal
        view
        returns (uint256 allowance_)
    {
        _checkContract(token);
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeCall(IERC20.allowance, (owner, spender)));
        if (!success || data.length < 32) {
            revert AllowanceQueryFailed(address(token), owner, spender);
        }
        assembly ("memory-safe") {
            allowance_ := mload(add(data, 0x20))
        }
    }

    function _callOptionalBool(IERC20 token, bytes memory callData) private returns (bool) {
        (bool success, bytes memory returnData) = address(token).call(callData);
        if (!success) return false;
        if (returnData.length == 0) return true;
        if (returnData.length < 32) return false;

        uint256 returned;
        assembly ("memory-safe") {
            returned := mload(add(returnData, 0x20))
        }
        return returned == 1;
    }

    function _checkContract(IERC20 token) private view {
        if (address(token).code.length == 0) revert TokenIsNotContract(address(token));
    }
}
