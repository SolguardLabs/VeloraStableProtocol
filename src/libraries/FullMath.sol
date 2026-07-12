// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Full-precision unsigned integer arithmetic.
library FullMath {
    error DivisionByZero();
    error MulDivOverflow();

    /// @notice Calculates floor(x * y / denominator) with 512-bit intermediate precision.
    function mulDiv(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        if (denominator == 0) revert DivisionByZero();

        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            if (prod1 == 0) return prod0 / denominator;
            if (denominator <= prod1) revert MulDivOverflow();

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            uint256 twos = denominator & (~denominator + 1);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }

    /// @notice Calculates ceil(x * y / denominator) with 512-bit intermediate precision.
    function mulDivUp(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) {
            if (result == type(uint256).max) revert MulDivOverflow();
            unchecked {
                ++result;
            }
        }
    }

    /// @notice Calculates x * y / denominator rounded to the nearest integer.
    /// @dev Exact half-way values round away from zero.
    function mulDivNearest(uint256 x, uint256 y, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(x, y, denominator);
        uint256 remainder = mulmod(x, y, denominator);
        if (remainder != 0 && remainder >= denominator - remainder) {
            if (result == type(uint256).max) revert MulDivOverflow();
            unchecked {
                ++result;
            }
        }
    }

    /// @notice Calculates ceil(value / denominator).
    function ceilDiv(uint256 value, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) revert DivisionByZero();
        if (value == 0) return 0;
        unchecked {
            return ((value - 1) / denominator) + 1;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @notice Overflow-safe floor average.
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a & b) + ((a ^ b) >> 1);
    }
}
