// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { CollateralRegistry } from "../core/CollateralRegistry.sol";
import { VaultManager } from "../core/VaultManager.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { LiquidationMath } from "../libraries/LiquidationMath.sol";
import { StabilityPool } from "../pools/StabilityPool.sol";
import {
    CollateralConfig,
    LiquidationQuote,
    RiskSnapshot,
    VaultData
} from "../types/VeloraTypes.sol";

/// @title LiquidationEngine
/// @notice Prices and settles under-collateralized Velora vaults.
contract LiquidationEngine is ProtocolAccess {
    uint256 public constant BPS = 10_000;

    VaultManager public immutable vaultManager;
    CollateralRegistry public immutable collateralRegistry;

    StabilityPool public stabilityPool;
    uint16 public closeFactorBps = 5000;
    uint16 public fullLiquidationRatioBps = 10_000;
    bool public paused;

    uint256 private _entered = 1;

    error LiquidationZeroAddress();
    error LiquidationNotContract(address account);
    error LiquidationPaused();
    error LiquidationReentrantCall();
    error LiquidationHealthyVault(uint256 ratioBps, uint256 thresholdBps);
    error LiquidationNothingAvailable();
    error LiquidationSlippage(uint256 collateralOut, uint256 minimumOut);
    error LiquidationBadParameters(uint256 closeFactorBps, uint256 fullRatioBps);
    error LiquidationPoolUnavailable();
    error LiquidationPoolAccounting(uint256 requested, uint256 accounted);

    event LiquidationSettled(
        uint256 indexed vaultId,
        address indexed payer,
        address indexed recipient,
        uint256 debtCovered,
        uint256 collateralSeized,
        bool stabilityPoolOffset
    );
    event StabilityPoolUpdated(address indexed previousPool, address indexed newPool);
    event LiquidationParametersUpdated(uint16 closeFactorBps, uint16 fullLiquidationRatioBps);
    event LiquidationPauseUpdated(bool paused);

    modifier nonReentrant() {
        if (_entered != 1) revert LiquidationReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert LiquidationPaused();
        _;
    }

    constructor(
        address initialAdmin,
        VaultManager vaultManager_,
        CollateralRegistry collateralRegistry_
    ) ProtocolAccess(initialAdmin) {
        if (address(vaultManager_) == address(0) || address(collateralRegistry_) == address(0)) {
            revert LiquidationZeroAddress();
        }
        if (address(vaultManager_).code.length == 0) {
            revert LiquidationNotContract(address(vaultManager_));
        }
        if (address(collateralRegistry_).code.length == 0) {
            revert LiquidationNotContract(address(collateralRegistry_));
        }
        vaultManager = vaultManager_;
        collateralRegistry = collateralRegistry_;
    }

    /// @notice Returns the executable quote for a vault at current oracle prices.
    function quote(uint256 vaultId, uint256 maxDebtToCover)
        public
        view
        returns (LiquidationQuote memory result)
    {
        if (maxDebtToCover == 0) revert LiquidationNothingAvailable();

        VaultData memory vault = vaultManager.getVault(vaultId);
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        RiskSnapshot memory risk = vaultManager.riskSnapshot(vaultId);
        if (!risk.liquidatable) {
            revert LiquidationHealthyVault(risk.ratioBps, config.liquidationRatioBps);
        }

        uint256 debt = vaultManager.accountedDebt(vaultId);
        uint256 factorLimit = debt;
        if (risk.ratioBps > fullLiquidationRatioBps) {
            factorLimit = LiquidationMath.closeFactorLimit(debt, closeFactorBps);
            if (factorLimit == 0 || debt - factorLimit < config.minDebt) factorLimit = debt;
        }

        uint256 requested = FullMath.min(maxDebtToCover, factorLimit);
        uint256 price = collateralRegistry.priceOracle().getPrice(config.oracleId);
        result = LiquidationMath.quote(
            debt,
            vault.collateralAmount,
            requested,
            price,
            config.decimals,
            config.liquidationBonusBps
        );
    }

    /// @notice Settles a liquidation using stablecoin supplied by the caller.
    /// @dev The caller approves the VaultManager, which performs the burn.
    function liquidate(
        uint256 vaultId,
        uint256 maxDebtToCover,
        uint256 minimumCollateralOut,
        address recipient
    ) external nonReentrant whenNotPaused returns (LiquidationQuote memory result) {
        if (recipient == address(0)) revert LiquidationZeroAddress();
        result = quote(vaultId, maxDebtToCover);
        if (result.collateralSeized < minimumCollateralOut) {
            revert LiquidationSlippage(result.collateralSeized, minimumCollateralOut);
        }

        uint256 actualCollateral = vaultManager.executeLiquidation(
            vaultId, result.debtCovered, result.collateralSeized, msg.sender, recipient
        );
        if (actualCollateral < minimumCollateralOut) {
            revert LiquidationSlippage(actualCollateral, minimumCollateralOut);
        }
        _recognizeIfExhausted(vaultId);
        result.collateralSeized = actualCollateral;
        emit LiquidationSettled(
            vaultId, msg.sender, recipient, result.debtCovered, actualCollateral, false
        );
    }

    /// @notice Uses pool deposits to offset debt and assigns seized collateral pro rata.
    function liquidateWithStabilityPool(
        uint256 vaultId,
        uint256 maxDebtToCover,
        uint256 minimumCollateralOut
    ) external nonReentrant whenNotPaused returns (LiquidationQuote memory result) {
        StabilityPool pool = stabilityPool;
        if (address(pool) == address(0)) revert LiquidationPoolUnavailable();

        uint256 available = pool.totalDeposits();
        if (available == 0) revert LiquidationNothingAvailable();
        result = quote(vaultId, FullMath.min(maxDebtToCover, available));
        if (result.collateralSeized < minimumCollateralOut) {
            revert LiquidationSlippage(result.collateralSeized, minimumCollateralOut);
        }

        VaultData memory vault = vaultManager.getVault(vaultId);
        uint256 actualCollateral = vaultManager.executeLiquidation(
            vaultId, result.debtCovered, result.collateralSeized, address(pool), address(pool)
        );
        if (actualCollateral < minimumCollateralOut) {
            revert LiquidationSlippage(actualCollateral, minimumCollateralOut);
        }
        uint256 offset = pool.offset(vault.collateralToken, result.debtCovered, actualCollateral);
        if (offset != result.debtCovered) {
            revert LiquidationPoolAccounting(result.debtCovered, offset);
        }

        _recognizeIfExhausted(vaultId);
        result.collateralSeized = actualCollateral;
        emit LiquidationSettled(
            vaultId, address(pool), address(pool), result.debtCovered, actualCollateral, true
        );
    }

    function setStabilityPool(StabilityPool newPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newPool) != address(0) && address(newPool).code.length == 0) {
            revert LiquidationNotContract(address(newPool));
        }
        address previous = address(stabilityPool);
        stabilityPool = newPool;
        emit StabilityPoolUpdated(previous, address(newPool));
    }

    function setLiquidationParameters(uint16 closeFactor, uint16 fullRatio)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (closeFactor == 0 || closeFactor > BPS || fullRatio > BPS) {
            revert LiquidationBadParameters(closeFactor, fullRatio);
        }
        closeFactorBps = closeFactor;
        fullLiquidationRatioBps = fullRatio;
        emit LiquidationParametersUpdated(closeFactor, fullRatio);
    }

    function setPaused(bool paused_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = paused_;
        emit LiquidationPauseUpdated(paused_);
    }

    function _recognizeIfExhausted(uint256 vaultId) internal {
        VaultData memory vault = vaultManager.getVault(vaultId);
        if (vault.collateralAmount == 0 && vaultManager.accountedDebt(vaultId) != 0) {
            vaultManager.recognizeBadDebt(vaultId);
        }
    }
}
