// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LiquidationQuote } from "../types/VeloraTypes.sol";
import { CollateralMath } from "./CollateralMath.sol";
import { FullMath } from "./FullMath.sol";
import { PercentageMath } from "./PercentageMath.sol";

/// @notice Deterministic liquidation quotes with collateral-aware clamping.
library LiquidationMath {
    uint256 internal constant BPS = 10_000;

    error NothingToLiquidate();
    error BonusOutOfRange(uint256 bonusBps);
    error CloseFactorOutOfRange(uint256 closeFactorBps);

    /// @notice Quotes a liquidation bounded by requested debt and available collateral.
    /// @dev Price uses 18-decimal stablecoin units per whole collateral token.
    function quote(
        uint256 outstandingDebt,
        uint256 collateralAmount,
        uint256 maxDebtToCover,
        uint256 price,
        uint8 collateralDecimals,
        uint256 bonusBps
    ) internal pure returns (LiquidationQuote memory result) {
        if (outstandingDebt == 0 || collateralAmount == 0 || maxDebtToCover == 0) {
            revert NothingToLiquidate();
        }
        if (bonusBps > BPS) revert BonusOutOfRange(bonusBps);

        result.requestedDebt = FullMath.min(outstandingDebt, maxDebtToCover);
        uint256 baseCollateral = CollateralMath.tokenAmountForValue(
            result.requestedDebt, price, collateralDecimals, true
        );
        uint256 bonusCollateral = PercentageMath.percentMulUp(baseCollateral, bonusBps);
        uint256 desiredSeizure = baseCollateral + bonusCollateral;

        if (desiredSeizure <= collateralAmount) {
            result.debtCovered = result.requestedDebt;
            result.collateralSeized = desiredSeizure;
            result.bonusCollateral = bonusCollateral;
        } else {
            uint256 supportedBase = FullMath.mulDiv(collateralAmount, BPS, BPS + bonusBps);
            uint256 supportedDebt =
                CollateralMath.collateralValue(supportedBase, price, collateralDecimals, false);
            result.debtCovered = FullMath.min(result.requestedDebt, supportedDebt);
            if (result.debtCovered == 0) revert NothingToLiquidate();

            baseCollateral = CollateralMath.tokenAmountForValue(
                result.debtCovered, price, collateralDecimals, true
            );
            bonusCollateral = PercentageMath.percentMulUp(baseCollateral, bonusBps);
            result.collateralSeized =
                FullMath.min(collateralAmount, baseCollateral + bonusCollateral);
            result.bonusCollateral = result.collateralSeized > baseCollateral
                ? result.collateralSeized - baseCollateral
                : 0;
        }

        unchecked {
            result.remainingDebt = outstandingDebt - result.debtCovered;
            result.remainingCollateral = collateralAmount - result.collateralSeized;
        }
        result.closesVault = result.remainingDebt == 0;
    }

    /// @notice Returns the maximum debt value supportable by collateral including bonus.
    function maxDebtSupported(
        uint256 collateralAmount,
        uint256 price,
        uint8 collateralDecimals,
        uint256 bonusBps
    ) internal pure returns (uint256) {
        if (bonusBps > BPS) revert BonusOutOfRange(bonusBps);
        uint256 baseCollateral = FullMath.mulDiv(collateralAmount, BPS, BPS + bonusBps);
        return CollateralMath.collateralValue(baseCollateral, price, collateralDecimals, false);
    }

    function closeFactorLimit(uint256 outstandingDebt, uint256 closeFactorBps)
        internal
        pure
        returns (uint256)
    {
        if (closeFactorBps > BPS) revert CloseFactorOutOfRange(closeFactorBps);
        return PercentageMath.percentMulDown(outstandingDebt, closeFactorBps);
    }
}
