// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { CollateralConfig } from "../src/types/VeloraTypes.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract CollateralDecimalsTest is VeloraTestBase {
    bytes32 internal constant USDC_ORACLE_ID = keccak256("USDC/USD");

    MockERC20 internal sixDecimalCollateral;

    function setUp() public override {
        super.setUp();
        sixDecimalCollateral = new MockERC20("USD Coin", "USDC", 6);
        oracle.configureFeed(USDC_ORACLE_ID, 1 days, 0.9 ether, 1.1 ether);
        oracle.reportPrice(USDC_ORACLE_ID, 1 ether);
        registry.registerCollateral(
            address(sixDecimalCollateral),
            CollateralConfig({
                enabled: true,
                decimals: 6,
                oracleId: USDC_ORACLE_ID,
                minCollateralRatioBps: 15_000,
                liquidationRatioBps: 12_000,
                liquidationBonusBps: 500,
                redemptionFeeBps: 20,
                debtCeiling: 5_000_000 ether,
                depositCap: 10_000_000e6,
                minDebt: 100 ether
            })
        );
    }

    function testValuationNormalizesSixDecimalCollateral() public view {
        assertEq(registry.collateralValue(address(sixDecimalCollateral), 1e6), 1 ether);
        assertEq(registry.tokenAmountForValue(address(sixDecimalCollateral), 250 ether), 250e6);
    }

    function testDepositCapUsesRawTokenUnits() public {
        sixDecimalCollateral.mint(alice, 1000e6);
        vm.startPrank(alice);
        sixDecimalCollateral.approve(address(vaultManager), type(uint256).max);
        uint256 vaultId = vaultManager.openVault(address(sixDecimalCollateral), 1000e6);
        vm.stopPrank();

        assertEq(vaultManager.totalCollateral(address(sixDecimalCollateral)), 1000e6);
        assertEq(vaultManager.getVault(vaultId).collateralAmount, 1000e6);
    }
}
