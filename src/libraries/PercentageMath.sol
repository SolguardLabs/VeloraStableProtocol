// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FullMath } from "./FullMath.sol";

/// @notice Basis-point arithmetic with explicit rounding direction.
library PercentageMath {
    uint256 internal constant BPS = 10_000;

    error BasisPointsOutOfRange(uint256 bps);

    function percentMulDown(uint256 value, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(value, bps, BPS);
    }

    function percentMulUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDivUp(value, bps, BPS);
    }

    function percentDivDown(uint256 value, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDiv(value, BPS, bps);
    }

    function percentDivUp(uint256 value, uint256 bps) internal pure returns (uint256) {
        return FullMath.mulDivUp(value, BPS, bps);
    }

    /// @notice Returns numerator / denominator expressed in basis points.
    function ratioBps(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return type(uint256).max;
        return FullMath.mulDiv(numerator, BPS, denominator);
    }

    /// @notice Returns the unused portion of a fee or allocation below 100%.
    function complement(uint256 bps) internal pure returns (uint256) {
        if (bps > BPS) revert BasisPointsOutOfRange(bps);
        return BPS - bps;
    }

    function isPercentage(uint256 bps) internal pure returns (bool) {
        return bps <= BPS;
    }

    /// @notice Interpolates between two values using a basis-point weight.
    function weightedAverage(uint256 start, uint256 end, uint256 weightBps)
        internal
        pure
        returns (uint256)
    {
        if (weightBps > BPS) revert BasisPointsOutOfRange(weightBps);
        if (end >= start) return start + percentMulDown(end - start, weightBps);
        return start - percentMulDown(start - end, weightBps);
    }

    /// @notice Absolute deviation from a reference, expressed in basis points.
    function deviationBps(uint256 observed, uint256 referenceValue)
        internal
        pure
        returns (uint256)
    {
        if (referenceValue == 0) return observed == 0 ? 0 : type(uint256).max;
        uint256 difference =
            observed > referenceValue ? observed - referenceValue : referenceValue - observed;
        return ratioBps(difference, referenceValue);
    }
}
