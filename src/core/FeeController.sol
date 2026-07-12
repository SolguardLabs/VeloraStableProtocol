// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { IFeeController } from "../interfaces/IVelora.sol";
import { FullMath } from "../libraries/FullMath.sol";

/// @title FeeController
/// @notice Quotes bounded protocol fees using configurable utilization and activity curves.
contract FeeController is ProtocolAccess, IFeeController {
    struct FeeCurve {
        uint16 baseRateBps;
        uint16 kinkBps;
        uint16 preKinkSlopeBps;
        uint16 postKinkSlopeBps;
        uint16 maxRateBps;
    }

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_PROTOCOL_FEE_BPS = 2000;

    FeeCurve private _mintCurve;
    FeeCurve private _redemptionCurve;

    uint256 public mintFeeCap;
    uint256 public redemptionFeeCap;

    error FeeInvalidCurve();
    error FeeFactorOutOfRange(uint256 factorBps);

    event MintCurveUpdated(FeeCurve curve);
    event RedemptionCurveUpdated(FeeCurve curve);
    event FeeCapsUpdated(uint256 mintFeeCap, uint256 redemptionFeeCap);

    constructor(address initialAdmin) ProtocolAccess(initialAdmin) {
        _mintCurve = FeeCurve({
            baseRateBps: 10,
            kinkBps: 8000,
            preKinkSlopeBps: 25,
            postKinkSlopeBps: 500,
            maxRateBps: 150
        });
        _redemptionCurve = FeeCurve({
            baseRateBps: 15,
            kinkBps: 6000,
            preKinkSlopeBps: 50,
            postKinkSlopeBps: 600,
            maxRateBps: 250
        });
        mintFeeCap = type(uint128).max;
        redemptionFeeCap = type(uint128).max;
    }

    function mintCurve() external view returns (FeeCurve memory) {
        return _mintCurve;
    }

    function redemptionCurve() external view returns (FeeCurve memory) {
        return _redemptionCurve;
    }

    function setMintCurve(FeeCurve calldata newCurve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateCurve(newCurve);
        _mintCurve = newCurve;
        emit MintCurveUpdated(newCurve);
    }

    function setRedemptionCurve(FeeCurve calldata newCurve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validateCurve(newCurve);
        _redemptionCurve = newCurve;
        emit RedemptionCurveUpdated(newCurve);
    }

    function setFeeCaps(uint256 newMintFeeCap, uint256 newRedemptionFeeCap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        mintFeeCap = newMintFeeCap;
        redemptionFeeCap = newRedemptionFeeCap;
        emit FeeCapsUpdated(newMintFeeCap, newRedemptionFeeCap);
    }

    /// @notice Quotes a mint fee for an amount and current collateral utilization.
    function mintFee(uint256 amount, uint256 utilizationBps)
        public
        view
        override
        returns (uint256)
    {
        uint256 rateBps = mintRate(utilizationBps);
        return _cappedFee(amount, rateBps, mintFeeCap);
    }

    /// @notice Quotes a redemption fee for an amount and recent redemption activity.
    function redemptionFee(uint256 amount, uint256 activityBps)
        public
        view
        override
        returns (uint256)
    {
        uint256 rateBps = redemptionRate(activityBps);
        return _cappedFee(amount, rateBps, redemptionFeeCap);
    }

    function mintRate(uint256 utilizationBps) public view returns (uint256) {
        _validateFactor(utilizationBps);
        return _rateAt(_mintCurve, utilizationBps);
    }

    function redemptionRate(uint256 activityBps) public view returns (uint256) {
        _validateFactor(activityBps);
        return _rateAt(_redemptionCurve, activityBps);
    }

    function quoteMint(uint256 amount, uint256 utilizationBps)
        external
        view
        returns (uint256 feeAmount, uint256 netAmount, uint256 rateBps)
    {
        rateBps = mintRate(utilizationBps);
        feeAmount = _cappedFee(amount, rateBps, mintFeeCap);
        netAmount = amount > feeAmount ? amount - feeAmount : 0;
    }

    function quoteRedemption(uint256 amount, uint256 activityBps)
        external
        view
        returns (uint256 feeAmount, uint256 netAmount, uint256 rateBps)
    {
        rateBps = redemptionRate(activityBps);
        feeAmount = _cappedFee(amount, rateBps, redemptionFeeCap);
        netAmount = amount > feeAmount ? amount - feeAmount : 0;
    }

    function _rateAt(FeeCurve memory curve, uint256 factorBps)
        internal
        pure
        returns (uint256 rateBps)
    {
        rateBps = curve.baseRateBps;
        uint256 preKinkFactor = factorBps < curve.kinkBps ? factorBps : curve.kinkBps;
        rateBps += FullMath.mulDiv(preKinkFactor, curve.preKinkSlopeBps, BPS);
        if (factorBps > curve.kinkBps) {
            rateBps += FullMath.mulDiv(factorBps - curve.kinkBps, curve.postKinkSlopeBps, BPS);
        }
        if (rateBps > curve.maxRateBps) rateBps = curve.maxRateBps;
    }

    function _cappedFee(uint256 amount, uint256 rateBps, uint256 cap)
        internal
        pure
        returns (uint256)
    {
        uint256 feeAmount = FullMath.mulDivUp(amount, rateBps, BPS);
        return feeAmount > cap ? cap : feeAmount;
    }

    function _validateCurve(FeeCurve calldata curve) internal pure {
        if (
            curve.kinkBps > BPS || curve.baseRateBps > curve.maxRateBps
                || curve.maxRateBps > MAX_PROTOCOL_FEE_BPS
                || curve.preKinkSlopeBps > MAX_PROTOCOL_FEE_BPS
                || curve.postKinkSlopeBps > MAX_PROTOCOL_FEE_BPS
        ) revert FeeInvalidCurve();
    }

    function _validateFactor(uint256 factorBps) internal pure {
        if (factorBps > BPS) revert FeeFactorOutOfRange(factorBps);
    }
}
