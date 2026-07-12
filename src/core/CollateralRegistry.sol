// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { ICollateralRegistry, IPriceOracle } from "../interfaces/IVelora.sol";
import { CollateralConfig } from "../types/VeloraTypes.sol";
import { FullMath } from "../libraries/FullMath.sol";

/// @title CollateralRegistry
/// @notice Governance registry for collateral risk parameters and normalized valuation.
contract CollateralRegistry is ProtocolAccess, ICollateralRegistry {
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_COLLATERAL_RATIO_BPS = 60_000;
    uint16 public constant MAX_LIQUIDATION_BONUS_BPS = 5000;
    uint16 public constant MAX_REDEMPTION_FEE_BPS = 2000;
    uint8 public constant MAX_TOKEN_DECIMALS = 18;

    mapping(address collateralToken => CollateralConfig config) private _configs;
    mapping(address collateralToken => uint256 indexPlusOne) private _indices;
    address[] private _collateralTokens;

    IPriceOracle public priceOracle;

    error RegistryZeroAddress();
    error RegistryNotContract(address account);
    error RegistryAlreadyRegistered(address collateralToken);
    error RegistryNotRegistered(address collateralToken);
    error RegistryInvalidOracleId();
    error RegistryUnsupportedDecimals(uint8 decimals);
    error RegistryInvalidRatios(uint16 minCollateralRatioBps, uint16 liquidationRatioBps);
    error RegistryInvalidLiquidationBonus(uint16 liquidationBonusBps);
    error RegistryInvalidRedemptionFee(uint16 redemptionFeeBps);
    error RegistryInvalidDebtLimits(uint256 minDebt, uint256 debtCeiling);
    error RegistryInvalidDepositCap(uint256 depositCap);
    error RegistryDepositCapExceeded(
        address collateralToken, uint256 resultingDeposit, uint256 depositCap
    );
    error RegistryDebtCeilingExceeded(
        address collateralToken, uint256 resultingDebt, uint256 debtCeiling
    );
    error RegistryIndexOutOfBounds(uint256 index);
    error RegistryInvalidPage();

    event PriceOracleUpdated(address indexed previousOracle, address indexed newOracle);
    event CollateralRegistered(
        address indexed collateralToken,
        bytes32 indexed oracleId,
        uint8 decimals,
        uint256 debtCeiling,
        uint256 depositCap
    );
    event CollateralConfigUpdated(address indexed collateralToken, CollateralConfig config);
    event CollateralStatusChanged(address indexed collateralToken, bool enabled);

    constructor(address initialAdmin, address initialPriceOracle) ProtocolAccess(initialAdmin) {
        _setPriceOracle(initialPriceOracle);
    }

    function registerCollateral(address collateralToken, CollateralConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _validateToken(collateralToken);
        if (_indices[collateralToken] != 0) revert RegistryAlreadyRegistered(collateralToken);
        _validateConfig(config);

        _configs[collateralToken] = config;
        _collateralTokens.push(collateralToken);
        _indices[collateralToken] = _collateralTokens.length;

        emit CollateralRegistered(
            collateralToken, config.oracleId, config.decimals, config.debtCeiling, config.depositCap
        );
        emit CollateralConfigUpdated(collateralToken, config);
    }

    function updateCollateral(address collateralToken, CollateralConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireRegistered(collateralToken);
        _validateConfig(config);
        _configs[collateralToken] = config;
        emit CollateralConfigUpdated(collateralToken, config);
    }

    function setCollateralEnabled(address collateralToken, bool enabled)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _requireRegistered(collateralToken);
        CollateralConfig storage config = _configs[collateralToken];
        if (config.enabled != enabled) {
            config.enabled = enabled;
            emit CollateralStatusChanged(collateralToken, enabled);
        }
    }

    function setPriceOracle(address newPriceOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setPriceOracle(newPriceOracle);
    }

    function getConfig(address collateralToken)
        external
        view
        override
        returns (CollateralConfig memory config)
    {
        _requireRegistered(collateralToken);
        return _configs[collateralToken];
    }

    function tryGetConfig(address collateralToken)
        external
        view
        returns (bool registered, CollateralConfig memory config)
    {
        registered = _indices[collateralToken] != 0;
        config = _configs[collateralToken];
    }

    function isRegistered(address collateralToken) external view returns (bool) {
        return _indices[collateralToken] != 0;
    }

    function isEnabled(address collateralToken) external view returns (bool) {
        return _indices[collateralToken] != 0 && _configs[collateralToken].enabled;
    }

    function collateralValue(address collateralToken, uint256 tokenAmount)
        external
        view
        override
        returns (uint256 value)
    {
        CollateralConfig storage config = _registeredConfig(collateralToken);
        uint256 price = priceOracle.getPrice(config.oracleId);
        return FullMath.mulDiv(tokenAmount, price, _tokenUnit(config.decimals));
    }

    function tokenAmountForValue(address collateralToken, uint256 value)
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        return _tokenAmountForValue(collateralToken, value, false);
    }

    function tokenAmountForValue(address collateralToken, uint256 value, bool roundUp)
        external
        view
        override
        returns (uint256 tokenAmount)
    {
        return _tokenAmountForValue(collateralToken, value, roundUp);
    }

    function validateDepositCapacity(
        address collateralToken,
        uint256 currentDeposits,
        uint256 addedAmount
    ) external view {
        CollateralConfig storage config = _registeredConfig(collateralToken);
        uint256 resultingDeposit = currentDeposits + addedAmount;
        if (resultingDeposit > config.depositCap) {
            revert RegistryDepositCapExceeded(collateralToken, resultingDeposit, config.depositCap);
        }
    }

    function validateDebtCapacity(address collateralToken, uint256 currentDebt, uint256 addedDebt)
        external
        view
    {
        CollateralConfig storage config = _registeredConfig(collateralToken);
        uint256 resultingDebt = currentDebt + addedDebt;
        if (resultingDebt > config.debtCeiling) {
            revert RegistryDebtCeilingExceeded(collateralToken, resultingDebt, config.debtCeiling);
        }
    }

    function collateralCount() external view returns (uint256) {
        return _collateralTokens.length;
    }

    function collateralAt(uint256 index) external view returns (address) {
        if (index >= _collateralTokens.length) revert RegistryIndexOutOfBounds(index);
        return _collateralTokens[index];
    }

    function collateralPage(uint256 offset, uint256 count)
        external
        view
        returns (address[] memory page)
    {
        uint256 length = _collateralTokens.length;
        if (offset > length || count > length - offset) revert RegistryInvalidPage();
        page = new address[](count);
        for (uint256 i; i < count; ++i) {
            page[i] = _collateralTokens[offset + i];
        }
    }

    function _tokenAmountForValue(address collateralToken, uint256 value, bool roundUp)
        internal
        view
        returns (uint256)
    {
        CollateralConfig storage config = _registeredConfig(collateralToken);
        uint256 price = priceOracle.getPrice(config.oracleId);
        uint256 unit = _tokenUnit(config.decimals);
        return roundUp ? FullMath.mulDivUp(value, unit, price) : FullMath.mulDiv(value, unit, price);
    }

    function _setPriceOracle(address newPriceOracle) internal {
        if (newPriceOracle == address(0)) revert RegistryZeroAddress();
        if (newPriceOracle.code.length == 0) revert RegistryNotContract(newPriceOracle);
        address previousOracle = address(priceOracle);
        priceOracle = IPriceOracle(newPriceOracle);
        emit PriceOracleUpdated(previousOracle, newPriceOracle);
    }

    function _validateToken(address collateralToken) internal view {
        if (collateralToken == address(0)) revert RegistryZeroAddress();
        if (collateralToken.code.length == 0) revert RegistryNotContract(collateralToken);
    }

    function _validateConfig(CollateralConfig calldata config) internal pure {
        if (config.oracleId == bytes32(0)) revert RegistryInvalidOracleId();
        if (config.decimals > MAX_TOKEN_DECIMALS) {
            revert RegistryUnsupportedDecimals(config.decimals);
        }
        if (
            config.liquidationRatioBps < BPS
                || config.minCollateralRatioBps <= config.liquidationRatioBps
                || config.minCollateralRatioBps > MAX_COLLATERAL_RATIO_BPS
        ) {
            revert RegistryInvalidRatios(config.minCollateralRatioBps, config.liquidationRatioBps);
        }
        if (config.liquidationBonusBps > MAX_LIQUIDATION_BONUS_BPS) {
            revert RegistryInvalidLiquidationBonus(config.liquidationBonusBps);
        }
        if (config.redemptionFeeBps > MAX_REDEMPTION_FEE_BPS) {
            revert RegistryInvalidRedemptionFee(config.redemptionFeeBps);
        }
        if (config.minDebt == 0 || config.debtCeiling < config.minDebt) {
            revert RegistryInvalidDebtLimits(config.minDebt, config.debtCeiling);
        }
        if (config.depositCap == 0) revert RegistryInvalidDepositCap(config.depositCap);
    }

    function _requireRegistered(address collateralToken) internal view {
        if (_indices[collateralToken] == 0) revert RegistryNotRegistered(collateralToken);
    }

    function _registeredConfig(address collateralToken)
        internal
        view
        returns (CollateralConfig storage config)
    {
        _requireRegistered(collateralToken);
        return _configs[collateralToken];
    }

    function _tokenUnit(uint8 tokenDecimals) internal pure returns (uint256) {
        return 10 ** uint256(tokenDecimals);
    }
}
