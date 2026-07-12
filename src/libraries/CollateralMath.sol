// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CollateralConfig, PriceData } from "../types/VeloraTypes.sol";
import { FullMath } from "./FullMath.sol";
import { PercentageMath } from "./PercentageMath.sol";

/// @notice Valuation and collateral-ratio arithmetic for configured assets.
library CollateralMath {
    uint8 internal constant MAX_SUPPORTED_DECIMALS = 36;
    uint256 internal constant BPS = 10_000;

    error UnsupportedDecimals(uint8 decimals);
    error InvalidOracleId();
    error InvalidCollateralRatios(uint256 minimumBps, uint256 liquidationBps);
    error FeeOutOfRange(uint256 bps);
    error InvalidPrice();
    error PriceFromFuture(uint256 updatedAt, uint256 currentTime);
    error PriceExpired(uint256 validUntil, uint256 currentTime);

    /// @notice Validates immutable arithmetic assumptions of a collateral configuration.
    function validateConfig(CollateralConfig memory config) internal pure {
        if (config.decimals > MAX_SUPPORTED_DECIMALS) {
            revert UnsupportedDecimals(config.decimals);
        }
        if (config.oracleId == bytes32(0)) revert InvalidOracleId();
        if (
            config.liquidationRatioBps < BPS
                || config.minCollateralRatioBps <= config.liquidationRatioBps
        ) {
            revert InvalidCollateralRatios(config.minCollateralRatioBps, config.liquidationRatioBps);
        }
        if (config.liquidationBonusBps > BPS) {
            revert FeeOutOfRange(config.liquidationBonusBps);
        }
        if (config.redemptionFeeBps > BPS) {
            revert FeeOutOfRange(config.redemptionFeeBps);
        }
    }

    /// @notice Validates an oracle observation and returns its normalized price.
    function validatedPrice(PriceData memory data, uint256 currentTime)
        internal
        pure
        returns (uint256)
    {
        if (data.price == 0 || data.updatedAt == 0) revert InvalidPrice();
        if (data.updatedAt > currentTime) revert PriceFromFuture(data.updatedAt, currentTime);
        if (data.validUntil != 0 && currentTime > data.validUntil) {
            revert PriceExpired(data.validUntil, currentTime);
        }
        return data.price;
    }

    /// @notice Converts raw collateral units to 18-decimal value units.
    function collateralValue(uint256 tokenAmount, uint256 price, uint8 decimals, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        _checkInputs(price, decimals);
        uint256 scale = 10 ** decimals;
        return roundUp
            ? FullMath.mulDivUp(tokenAmount, price, scale)
            : FullMath.mulDiv(tokenAmount, price, scale);
    }

    /// @notice Converts 18-decimal value units to raw collateral units.
    function tokenAmountForValue(uint256 value, uint256 price, uint8 decimals, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        _checkInputs(price, decimals);
        uint256 scale = 10 ** decimals;
        return
            roundUp ? FullMath.mulDivUp(value, scale, price) : FullMath.mulDiv(value, scale, price);
    }

    function collateralRatioBps(uint256 collateralValue_, uint256 debtValue)
        internal
        pure
        returns (uint256)
    {
        return PercentageMath.ratioBps(collateralValue_, debtValue);
    }

    function requiredCollateralValue(uint256 debtValue, uint256 ratioBps, bool roundUp)
        internal
        pure
        returns (uint256)
    {
        return roundUp
            ? PercentageMath.percentMulUp(debtValue, ratioBps)
            : PercentageMath.percentMulDown(debtValue, ratioBps);
    }

    function requiredTokenAmount(uint256 debtValue, uint256 ratioBps, uint256 price, uint8 decimals)
        internal
        pure
        returns (uint256)
    {
        uint256 requiredValue = requiredCollateralValue(debtValue, ratioBps, true);
        return tokenAmountForValue(requiredValue, price, decimals, true);
    }

    /// @notice Returns collateral that can leave while preserving the minimum ratio.
    function maxWithdrawable(
        uint256 collateralAmount,
        uint256 debtValue,
        uint256 price,
        uint8 decimals,
        uint256 minimumRatioBps
    ) internal pure returns (uint256) {
        if (debtValue == 0) return collateralAmount;
        uint256 required = requiredTokenAmount(debtValue, minimumRatioBps, price, decimals);
        return required < collateralAmount ? collateralAmount - required : 0;
    }

    function isLiquidatable(
        uint256 collateralValue_,
        uint256 debtValue,
        uint256 liquidationRatioBps
    ) internal pure returns (bool) {
        return debtValue != 0
            && collateralRatioBps(collateralValue_, debtValue) < liquidationRatioBps;
    }

    function remainingCapacity(uint256 currentAmount, uint256 depositCap)
        internal
        pure
        returns (uint256)
    {
        return currentAmount < depositCap ? depositCap - currentAmount : 0;
    }

    /// @notice Maximum debt supported by a collateral value at a target ratio.
    function debtCapacity(uint256 collateralValue_, uint256 minimumRatioBps)
        internal
        pure
        returns (uint256)
    {
        return PercentageMath.percentDivDown(collateralValue_, minimumRatioBps);
    }

    function depositFitsCap(uint256 currentAmount, uint256 depositAmount, uint256 depositCap)
        internal
        pure
        returns (bool)
    {
        return depositAmount <= remainingCapacity(currentAmount, depositCap);
    }

    function _checkInputs(uint256 price, uint8 decimals) private pure {
        if (price == 0) revert InvalidPrice();
        if (decimals > MAX_SUPPORTED_DECIMALS) revert UnsupportedDecimals(decimals);
    }
}
