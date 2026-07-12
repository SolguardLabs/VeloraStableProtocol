// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FullMath } from "./FullMath.sol";

/// @notice Helpers for 18-decimal fixed-point values.
library WadMath {
    uint256 internal constant WAD = 1e18;
    uint8 internal constant WAD_DECIMALS = 18;
    uint8 internal constant MAX_SUPPORTED_DECIMALS = 36;

    error UnsupportedDecimals(uint8 decimals);
    error WadWeightOutOfRange(uint256 weight);

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, y, WAD);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivUp(x, y, WAD);
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDiv(x, WAD, y);
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return FullMath.mulDivUp(x, WAD, y);
    }

    /// @notice Converts token precision to WAD, rounding down when precision is removed.
    function toWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        _checkDecimals(decimals);
        if (decimals == WAD_DECIMALS) return value;
        if (decimals < WAD_DECIMALS) {
            return FullMath.mulDiv(value, 10 ** (WAD_DECIMALS - decimals), 1);
        }
        return value / (10 ** (decimals - WAD_DECIMALS));
    }

    /// @notice Converts token precision to WAD, rounding up when precision is removed.
    function toWadUp(uint256 value, uint8 decimals) internal pure returns (uint256) {
        _checkDecimals(decimals);
        if (decimals <= WAD_DECIMALS) return toWad(value, decimals);
        return FullMath.ceilDiv(value, 10 ** (decimals - WAD_DECIMALS));
    }

    /// @notice Converts WAD to token precision, rounding down.
    function fromWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        _checkDecimals(decimals);
        if (decimals == WAD_DECIMALS) return value;
        if (decimals < WAD_DECIMALS) return value / (10 ** (WAD_DECIMALS - decimals));
        return FullMath.mulDiv(value, 10 ** (decimals - WAD_DECIMALS), 1);
    }

    /// @notice Converts WAD to token precision, rounding up.
    function fromWadUp(uint256 value, uint8 decimals) internal pure returns (uint256) {
        _checkDecimals(decimals);
        if (decimals >= WAD_DECIMALS) return fromWad(value, decimals);
        return FullMath.ceilDiv(value, 10 ** (WAD_DECIMALS - decimals));
    }

    /// @notice Interpolates between two values using a WAD weight in [0, 1].
    function interpolate(uint256 start, uint256 end, uint256 weight)
        internal
        pure
        returns (uint256)
    {
        if (weight > WAD) revert WadWeightOutOfRange(weight);
        if (end >= start) return start + mulWadDown(end - start, weight);
        return start - mulWadDown(start - end, weight);
    }

    function clamp(uint256 value, uint256 lower, uint256 upper) internal pure returns (uint256) {
        if (value < lower) return lower;
        if (value > upper) return upper;
        return value;
    }

    function _checkDecimals(uint8 decimals) private pure {
        if (decimals > MAX_SUPPORTED_DECIMALS) revert UnsupportedDecimals(decimals);
    }
}
