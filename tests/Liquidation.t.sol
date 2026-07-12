// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LiquidationEngine } from "../src/modules/LiquidationEngine.sol";
import { LiquidationQuote, RiskSnapshot } from "../src/types/VeloraTypes.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract LiquidationTest is VeloraTestBase {
    LiquidationEngine internal liquidationEngine;

    function setUp() public override {
        super.setUp();
        liquidationEngine = new LiquidationEngine(address(this), vaultManager, registry);
        vaultManager.grantRole(vaultManager.LIQUIDATION_ROLE(), address(liquidationEngine));
    }

    function testPriceDropAllowsBoundedDirectLiquidation() public {
        uint256 vaultId = _openVault(alice, 2 ether);
        _mintStable(alice, vaultId, 2000 ether);
        oracle.reportPrice(WETH_ORACLE_ID, 1100 ether);

        RiskSnapshot memory risk = vaultManager.riskSnapshot(vaultId);
        assertTrue(risk.liquidatable);
        assertGt(risk.ratioBps, liquidationEngine.fullLiquidationRatioBps());

        uint256 debtBefore = debtLedger.accountedDebt(vaultId);
        LiquidationQuote memory quoted = liquidationEngine.quote(vaultId, type(uint256).max);
        assertEq(quoted.debtCovered, debtBefore / 2);
        assertGt(quoted.collateralSeized, 0);
        assertFalse(quoted.closesVault);

        vm.prank(alice);
        stablecoin.transfer(bob, quoted.debtCovered);
        uint256 bobCollateralBefore = collateral.balanceOf(bob);

        vm.prank(bob);
        LiquidationQuote memory settled =
            liquidationEngine.liquidate(vaultId, type(uint256).max, quoted.collateralSeized, bob);

        assertEq(settled.debtCovered, quoted.debtCovered);
        assertEq(collateral.balanceOf(bob), bobCollateralBefore + settled.collateralSeized);
        assertEq(debtLedger.accountedDebt(vaultId), debtBefore - settled.debtCovered);
    }

    function testQuoteRespectsConfiguredCloseFactor() public {
        uint256 vaultId = _openVault(alice, 3 ether);
        _mintStable(alice, vaultId, 3000 ether);
        oracle.reportPrice(WETH_ORACLE_ID, 1100 ether);

        liquidationEngine.setLiquidationParameters(2500, 10_000);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        LiquidationQuote memory result = liquidationEngine.quote(vaultId, type(uint256).max);

        assertEq(result.requestedDebt, (debt * 2500) / 10_000);
        assertEq(result.debtCovered, result.requestedDebt);
        assertEq(result.remainingDebt, debt - result.debtCovered);
    }

    function testLiquidationRejectsOutputBelowCallerMinimum() public {
        uint256 vaultId = _openVault(alice, 2 ether);
        _mintStable(alice, vaultId, 2000 ether);
        oracle.reportPrice(WETH_ORACLE_ID, 1100 ether);

        LiquidationQuote memory result = liquidationEngine.quote(vaultId, type(uint256).max);
        vm.prank(alice);
        stablecoin.transfer(bob, result.debtCovered);

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                LiquidationEngine.LiquidationSlippage.selector,
                result.collateralSeized,
                result.collateralSeized + 1
            )
        );
        liquidationEngine.liquidate(vaultId, type(uint256).max, result.collateralSeized + 1, bob);
    }
}
