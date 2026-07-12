// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";

import { CollateralRegistry } from "../../src/core/CollateralRegistry.sol";
import { DebtLedger } from "../../src/core/DebtLedger.sol";
import { FeeController } from "../../src/core/FeeController.sol";
import { VaultManager } from "../../src/core/VaultManager.sol";
import { VeloraPriceOracle } from "../../src/oracle/VeloraPriceOracle.sol";
import { VeloraUSD } from "../../src/token/VeloraUSD.sol";
import { CollateralConfig } from "../../src/types/VeloraTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

abstract contract VeloraTestBase is Test {
    bytes32 internal constant WETH_ORACLE_ID = keccak256("WETH/USD");
    uint48 internal constant PRICE_HEARTBEAT = 1 days;
    uint256 internal constant INITIAL_PRICE = 2000 ether;
    uint256 internal constant USER_COLLATERAL = 1000 ether;
    uint256 internal constant MINIMUM_DEBT = 100 ether;

    address internal alice;
    address internal bob;
    address internal treasury;

    MockERC20 internal collateral;
    VeloraUSD internal stablecoin;
    VeloraPriceOracle internal oracle;
    CollateralRegistry internal registry;
    FeeController internal fees;
    DebtLedger internal debtLedger;
    VaultManager internal vaultManager;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");

        collateral = new MockERC20("Wrapped Ether", "WETH", 18);
        stablecoin = new VeloraUSD(address(this));
        oracle = new VeloraPriceOracle(address(this));
        oracle.grantRole(oracle.REPORTER_ROLE(), address(this));
        oracle.grantRole(oracle.GUARDIAN_ROLE(), address(this));
        oracle.configureFeed(WETH_ORACLE_ID, PRICE_HEARTBEAT, 100 ether, 10_000 ether);
        oracle.reportPrice(WETH_ORACLE_ID, INITIAL_PRICE);

        registry = new CollateralRegistry(address(this), address(oracle));
        registry.registerCollateral(
            address(collateral),
            CollateralConfig({
                enabled: true,
                decimals: 18,
                oracleId: WETH_ORACLE_ID,
                minCollateralRatioBps: 15_000,
                liquidationRatioBps: 12_000,
                liquidationBonusBps: 800,
                redemptionFeeBps: 30,
                debtCeiling: 20_000_000 ether,
                depositCap: 100_000 ether,
                minDebt: MINIMUM_DEBT
            })
        );

        fees = new FeeController(address(this));
        debtLedger = new DebtLedger(address(this));
        vaultManager =
            new VaultManager(address(this), stablecoin, debtLedger, registry, fees, treasury);

        stablecoin.grantRole(stablecoin.MINTER_ROLE(), address(vaultManager));
        stablecoin.grantRole(stablecoin.BURNER_ROLE(), address(vaultManager));
        stablecoin.grantRole(stablecoin.MINTER_ROLE(), address(this));
        debtLedger.grantRole(debtLedger.MANAGER_ROLE(), address(vaultManager));

        _prepareUser(alice);
        _prepareUser(bob);
    }

    function _prepareUser(address account) internal {
        collateral.mint(account, USER_COLLATERAL);
        vm.startPrank(account);
        collateral.approve(address(vaultManager), type(uint256).max);
        stablecoin.approve(address(vaultManager), type(uint256).max);
        vm.stopPrank();
    }

    function _openVault(address account, uint256 collateralAmount)
        internal
        returns (uint256 vaultId)
    {
        vm.prank(account);
        vaultId = vaultManager.openVault(address(collateral), collateralAmount);
    }

    function _mintStable(address account, uint256 vaultId, uint256 amount)
        internal
        returns (uint256 fee)
    {
        vm.prank(account);
        fee = vaultManager.mintStablecoin(vaultId, amount, account);
    }

    function _repayAll(address account, uint256 vaultId) internal {
        uint256 debt = debtLedger.accountedDebt(vaultId);
        uint256 accountBalance = stablecoin.balanceOf(account);
        if (accountBalance < debt) {
            vm.prank(treasury);
            stablecoin.transfer(account, debt - accountBalance);
        }
        vm.prank(account);
        vaultManager.repayDebt(vaultId, type(uint256).max);
    }
}
