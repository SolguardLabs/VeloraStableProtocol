// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { CollateralRegistry } from "../src/core/CollateralRegistry.sol";
import { DebtLedger } from "../src/core/DebtLedger.sol";
import { FeeController } from "../src/core/FeeController.sol";
import { VaultManager } from "../src/core/VaultManager.sol";
import { LiquidationEngine } from "../src/modules/LiquidationEngine.sol";
import { RedemptionQueue } from "../src/modules/RedemptionQueue.sol";
import { VeloraPriceOracle } from "../src/oracle/VeloraPriceOracle.sol";
import { StabilityPool } from "../src/pools/StabilityPool.sol";
import { SurplusPool } from "../src/pools/SurplusPool.sol";
import { VeloraUSD } from "../src/token/VeloraUSD.sol";
import { CollateralConfig } from "../src/types/VeloraTypes.sol";

/// @title DeployVelora
/// @notice Deploys and connects a complete Velora protocol instance.
contract DeployVelora is Script {
    struct Deployment {
        VeloraUSD stablecoin;
        VeloraPriceOracle priceOracle;
        CollateralRegistry collateralRegistry;
        FeeController feeController;
        DebtLedger debtLedger;
        VaultManager vaultManager;
        SurplusPool surplusPool;
        StabilityPool stabilityPool;
        LiquidationEngine liquidationEngine;
        RedemptionQueue redemptionQueue;
    }

    struct InitialCollateral {
        address token;
        uint8 decimals;
        uint48 heartbeat;
        uint256 price;
        uint256 debtCeiling;
        uint256 depositCap;
        uint256 minimumDebt;
    }

    error InvalidPrivateKey();
    error InvalidTreasury();
    error InvalidCollateralDecimals(uint256 decimals);
    error InvalidCollateralPrice(uint256 price);
    error InvalidCollateralHeartbeat(uint256 heartbeat);

    function run() external returns (Deployment memory deployment) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        if (privateKey == 0) revert InvalidPrivateKey();

        address deployer = vm.addr(privateKey);
        address treasury = vm.envOr("TREASURY", deployer);
        if (treasury == address(0)) revert InvalidTreasury();
        InitialCollateral memory initialCollateral = _readInitialCollateral();

        vm.startBroadcast(privateKey);

        deployment.stablecoin = new VeloraUSD(deployer);
        deployment.priceOracle = new VeloraPriceOracle(deployer);
        deployment.collateralRegistry =
            new CollateralRegistry(deployer, address(deployment.priceOracle));
        deployment.feeController = new FeeController(deployer);
        deployment.debtLedger = new DebtLedger(deployer);
        deployment.vaultManager = new VaultManager(
            deployer,
            deployment.stablecoin,
            deployment.debtLedger,
            deployment.collateralRegistry,
            deployment.feeController,
            treasury
        );
        deployment.surplusPool = new SurplusPool(deployer);
        deployment.stabilityPool = new StabilityPool(deployer, deployment.vaultManager);
        deployment.liquidationEngine = new LiquidationEngine(
            deployer, deployment.vaultManager, deployment.collateralRegistry
        );
        deployment.redemptionQueue =
            new RedemptionQueue(deployer, deployment.vaultManager, deployment.collateralRegistry);

        _wireProtocol(deployment, deployer);
        if (initialCollateral.token != address(0)) {
            _configureInitialCollateral(deployment, initialCollateral);
        }

        vm.stopBroadcast();
        _logDeployment(deployment, deployer, treasury, initialCollateral.token);
    }

    function _wireProtocol(Deployment memory deployment, address deployer) internal {
        deployment.priceOracle.grantRole(deployment.priceOracle.REPORTER_ROLE(), deployer);
        deployment.priceOracle.grantRole(deployment.priceOracle.GUARDIAN_ROLE(), deployer);
        deployment.stablecoin
            .grantRole(deployment.stablecoin.MINTER_ROLE(), address(deployment.vaultManager));
        deployment.stablecoin
            .grantRole(deployment.stablecoin.BURNER_ROLE(), address(deployment.vaultManager));
        deployment.debtLedger
            .grantRole(deployment.debtLedger.MANAGER_ROLE(), address(deployment.vaultManager));
        deployment.vaultManager.grantRole(deployment.vaultManager.GUARDIAN_ROLE(), deployer);
        deployment.vaultManager
            .grantRole(
                deployment.vaultManager.LIQUIDATION_ROLE(), address(deployment.liquidationEngine)
            );
        deployment.vaultManager
            .grantRole(
                deployment.vaultManager.REDEMPTION_ROLE(), address(deployment.redemptionQueue)
            );
        deployment.stabilityPool
            .grantRole(
                deployment.stabilityPool.OFFSET_ROLE(), address(deployment.liquidationEngine)
            );
        deployment.surplusPool
                .grantRole(
                deployment.surplusPool.ACCOUNTING_ROLE(), address(deployment.vaultManager)
            );

        deployment.vaultManager.setSurplusPool(address(deployment.surplusPool));
        deployment.liquidationEngine.setStabilityPool(deployment.stabilityPool);
    }

    function _readInitialCollateral() internal view returns (InitialCollateral memory settings) {
        settings.token = vm.envOr("COLLATERAL_TOKEN", address(0));
        if (settings.token == address(0)) return settings;

        uint256 decimals = vm.envOr("COLLATERAL_DECIMALS", uint256(18));
        if (decimals > 18) revert InvalidCollateralDecimals(decimals);
        settings.decimals = uint8(decimals);

        settings.price = vm.envOr("COLLATERAL_PRICE", uint256(2000 ether));
        if (settings.price == 0 || settings.price > type(uint192).max / 10) {
            revert InvalidCollateralPrice(settings.price);
        }

        uint256 heartbeat = vm.envOr("COLLATERAL_HEARTBEAT", uint256(1 days));
        if (heartbeat < 1 minutes || heartbeat > 7 days) {
            revert InvalidCollateralHeartbeat(heartbeat);
        }
        settings.heartbeat = uint48(heartbeat);
        settings.debtCeiling = vm.envOr("COLLATERAL_DEBT_CEILING", uint256(10_000_000 ether));
        settings.depositCap = vm.envOr(
            "COLLATERAL_DEPOSIT_CAP", uint256(1_000_000) * (10 ** uint256(settings.decimals))
        );
        settings.minimumDebt = vm.envOr("COLLATERAL_MINIMUM_DEBT", uint256(100 ether));
    }

    function _configureInitialCollateral(
        Deployment memory deployment,
        InitialCollateral memory settings
    ) internal {
        bytes32 oracleId = keccak256(abi.encodePacked("VELORA/USD/", settings.token));
        deployment.priceOracle
            .configureFeed(oracleId, settings.heartbeat, settings.price / 10, settings.price * 10);
        deployment.priceOracle.reportPrice(oracleId, settings.price);

        CollateralConfig memory config = CollateralConfig({
            enabled: true,
            decimals: settings.decimals,
            oracleId: oracleId,
            minCollateralRatioBps: 15_000,
            liquidationRatioBps: 12_500,
            liquidationBonusBps: 800,
            redemptionFeeBps: 30,
            debtCeiling: settings.debtCeiling,
            depositCap: settings.depositCap,
            minDebt: settings.minimumDebt
        });
        deployment.collateralRegistry.registerCollateral(settings.token, config);
    }

    function _logDeployment(
        Deployment memory deployment,
        address deployer,
        address treasury,
        address initialCollateral
    ) internal pure {
        console2.log("Velora deployer", deployer);
        console2.log("Velora treasury", treasury);
        console2.log("VeloraUSD", address(deployment.stablecoin));
        console2.log("VeloraPriceOracle", address(deployment.priceOracle));
        console2.log("CollateralRegistry", address(deployment.collateralRegistry));
        console2.log("FeeController", address(deployment.feeController));
        console2.log("DebtLedger", address(deployment.debtLedger));
        console2.log("VaultManager", address(deployment.vaultManager));
        console2.log("SurplusPool", address(deployment.surplusPool));
        console2.log("StabilityPool", address(deployment.stabilityPool));
        console2.log("LiquidationEngine", address(deployment.liquidationEngine));
        console2.log("RedemptionQueue", address(deployment.redemptionQueue));
        if (initialCollateral != address(0)) {
            console2.log("Initial collateral", initialCollateral);
        }
    }
}
