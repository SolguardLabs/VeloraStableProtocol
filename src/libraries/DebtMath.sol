// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { DebtPosition } from "../types/VeloraTypes.sol";
import { FullMath } from "./FullMath.sol";

/// @notice Conversion and settlement helpers for share-denominated debt.
library DebtMath {
    error InconsistentShareState(uint256 totalDebt, uint256 totalShares);
    error SharesExceedSupply(uint256 shares, uint256 totalShares);
    error DebtCeilingExceeded(uint256 debtAfter, uint256 debtCeiling);

    /// @notice Converts debt shares into debt units at the current global index.
    function debtForShares(uint256 shares, uint256 totalDebt, uint256 totalShares, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (shares == 0) return 0;
        if (totalShares == 0) revert InconsistentShareState(totalDebt, totalShares);
        if (shares > totalShares) revert SharesExceedSupply(shares, totalShares);
        return roundUp
            ? FullMath.mulDivUp(shares, totalDebt, totalShares)
            : FullMath.mulDiv(shares, totalDebt, totalShares);
    }

    /// @notice Converts debt units into shares at the current global index.
    function sharesForDebt(uint256 amount, uint256 totalDebt, uint256 totalShares, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        if (totalDebt == 0 && totalShares == 0) return amount;
        if (totalDebt == 0 || totalShares == 0) {
            revert InconsistentShareState(totalDebt, totalShares);
        }
        return roundUp
            ? FullMath.mulDivUp(amount, totalShares, totalDebt)
            : FullMath.mulDiv(amount, totalShares, totalDebt);
    }

    /// @notice Quotes the debt represented by a stored position.
    function positionDebt(DebtPosition memory position_, uint256 totalDebt, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return debtForShares(position_.shares, totalDebt, totalShares, true);
    }

    /// @notice Computes shares removable for a repayment without exceeding supply.
    function sharesForRepayment(uint256 repayment, uint256 totalDebt, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        if (repayment == 0 || totalDebt == 0) return 0;
        if (totalShares == 0) revert InconsistentShareState(totalDebt, totalShares);
        if (repayment >= totalDebt) return totalShares;
        return FullMath.mulDiv(repayment, totalShares, totalDebt);
    }

    /// @notice Clamps a repayment to outstanding debt and returns the residual.
    function applyRepayment(uint256 outstandingDebt, uint256 requestedRepayment)
        internal
        pure
        returns (uint256 applied, uint256 remaining)
    {
        applied = requestedRepayment < outstandingDebt ? requestedRepayment : outstandingDebt;
        unchecked {
            remaining = outstandingDebt - applied;
        }
    }

    /// @notice Returns debt remaining after a recorded pending repayment.
    function netOfPending(uint256 accountedDebt, uint256 pendingRepayment)
        internal
        pure
        returns (uint256)
    {
        return pendingRepayment < accountedDebt ? accountedDebt - pendingRepayment : 0;
    }

    /// @notice Returns aggregate debt after applying a bounded repayment.
    function totalAfterRepayment(uint256 totalDebt, uint256 repayment)
        internal
        pure
        returns (uint256)
    {
        return repayment < totalDebt ? totalDebt - repayment : 0;
    }

    /// @notice Validates and returns aggregate debt after a requested increase.
    function totalAfterIncrease(uint256 totalDebt, uint256 increase, uint256 debtCeiling)
        internal
        pure
        returns (uint256 debtAfter)
    {
        debtAfter = totalDebt + increase;
        if (debtAfter > debtCeiling) revert DebtCeilingExceeded(debtAfter, debtCeiling);
    }

    function meetsMinimumDebt(uint256 debt, uint256 minimumDebt) internal pure returns (bool) {
        return debt == 0 || debt >= minimumDebt;
    }

    function pendingIsBounded(DebtPosition memory position_, uint256 accountedDebt)
        internal
        pure
        returns (bool)
    {
        return position_.pendingRepayment <= accountedDebt;
    }
}
