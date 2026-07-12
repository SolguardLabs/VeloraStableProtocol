// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { VeloraPriceOracle } from "../src/oracle/VeloraPriceOracle.sol";
import { PriceData, RiskSnapshot } from "../src/types/VeloraTypes.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract OracleAndRiskTest is VeloraTestBase {
    function testPriceUpdateRefreshesValuationAndRisk() public {
        uint256 vaultId = _openVault(alice, 2 ether);
        _mintStable(alice, vaultId, 2000 ether);

        RiskSnapshot memory beforeUpdate = vaultManager.riskSnapshot(vaultId);
        assertEq(beforeUpdate.collateralValue, 4000 ether);
        assertFalse(beforeUpdate.liquidatable);

        oracle.reportPrice(WETH_ORACLE_ID, 1000 ether);
        RiskSnapshot memory afterUpdate = vaultManager.riskSnapshot(vaultId);
        assertEq(afterUpdate.collateralValue, 2000 ether);
        assertLt(afterUpdate.ratioBps, 12_000);
        assertTrue(afterUpdate.liquidatable);
    }

    function testPriceMetadataAdvancesWithReports() public {
        PriceData memory first = oracle.getPriceData(WETH_ORACLE_ID);
        assertEq(first.price, INITIAL_PRICE);
        assertEq(first.roundId, 1);

        vm.warp(block.timestamp + 1 hours);
        oracle.reportPrice(WETH_ORACLE_ID, 2100 ether);
        PriceData memory second = oracle.getPriceData(WETH_ORACLE_ID);

        assertEq(second.price, 2100 ether);
        assertEq(second.roundId, 2);
        assertGt(second.updatedAt, first.updatedAt);
        assertEq(second.validUntil, second.updatedAt + PRICE_HEARTBEAT);
        assertEq(registry.collateralValue(address(collateral), 2 ether), 4200 ether);
    }

    function testStalePriceIsRejectedUntilAReporterRefreshesIt() public {
        uint256 vaultId = _openVault(alice, 3 ether);
        _mintStable(alice, vaultId, 1000 ether);

        vm.warp(block.timestamp + PRICE_HEARTBEAT + 1);
        vm.expectPartialRevert(VeloraPriceOracle.OracleStalePrice.selector);
        oracle.getPrice(WETH_ORACLE_ID);

        vm.expectPartialRevert(VeloraPriceOracle.OracleStalePrice.selector);
        vaultManager.riskSnapshot(vaultId);

        oracle.reportPrice(WETH_ORACLE_ID, 1950 ether);
        assertEq(oracle.getPrice(WETH_ORACLE_ID), 1950 ether);
        assertFalse(vaultManager.riskSnapshot(vaultId).liquidatable);
    }

    function testFuzzRiskSnapshotTracksBoundedLivePrices(uint96 priceSeed) public {
        uint256 vaultId = _openVault(alice, 1 ether);
        _mintStable(alice, vaultId, 1000 ether);
        uint256 debt = debtLedger.accountedDebt(vaultId);

        uint256 price = bound(uint256(priceSeed), 500 ether, 3000 ether);
        oracle.reportPrice(WETH_ORACLE_ID, price);

        RiskSnapshot memory risk = vaultManager.riskSnapshot(vaultId);
        uint256 expectedRatio = (price * 10_000) / debt;
        assertEq(risk.collateralValue, price);
        assertEq(risk.debtValue, debt);
        assertEq(risk.ratioBps, expectedRatio);
        assertEq(risk.liquidatable, expectedRatio < 12_000);
    }
}
