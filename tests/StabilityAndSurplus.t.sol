// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { LiquidationEngine } from "../src/modules/LiquidationEngine.sol";
import { StabilityPool } from "../src/pools/StabilityPool.sol";
import { SurplusPool } from "../src/pools/SurplusPool.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract StabilityAndSurplusTest is VeloraTestBase {
    StabilityPool internal stabilityPool;
    SurplusPool internal surplusPool;
    LiquidationEngine internal liquidationEngine;

    function setUp() public override {
        super.setUp();
        stabilityPool = new StabilityPool(address(this), vaultManager);
        surplusPool = new SurplusPool(address(this));
        liquidationEngine = new LiquidationEngine(address(this), vaultManager, registry);

        liquidationEngine.setStabilityPool(stabilityPool);
        vaultManager.setSurplusPool(address(surplusPool));
        vaultManager.grantRole(vaultManager.LIQUIDATION_ROLE(), address(liquidationEngine));
        vaultManager.grantRole(vaultManager.LIQUIDATION_ROLE(), address(this));
        stabilityPool.grantRole(stabilityPool.OFFSET_ROLE(), address(liquidationEngine));
        stabilityPool.grantRole(stabilityPool.OFFSET_ROLE(), address(this));
        surplusPool.grantRole(surplusPool.ACCOUNTING_ROLE(), address(vaultManager));

        stablecoin.mint(alice, 2000 ether);
        stablecoin.mint(bob, 2000 ether);
        vm.prank(alice);
        stablecoin.approve(address(stabilityPool), type(uint256).max);
        vm.prank(bob);
        stablecoin.approve(address(stabilityPool), type(uint256).max);
    }

    function testDepositorsShareOffsetCollateralRewards() public {
        vm.prank(alice);
        stabilityPool.deposit(1000 ether);
        vm.prank(bob);
        stabilityPool.deposit(1000 ether);
        assertEq(stabilityPool.totalDeposits(), 2000 ether);

        collateral.mint(address(stabilityPool), 2 ether);
        stabilityPool.offset(address(collateral), 1000 ether, 2 ether);

        assertEq(stabilityPool.totalDeposits(), 1000 ether);
        assertEq(stabilityPool.depositOf(alice), 500 ether);
        assertEq(stabilityPool.depositOf(bob), 500 ether);
        assertEq(stabilityPool.pendingCollateralGain(alice, address(collateral)), 1 ether);
        assertEq(stabilityPool.pendingCollateralGain(bob, address(collateral)), 1 ether);

        uint256 aliceBefore = collateral.balanceOf(alice);
        vm.prank(alice);
        stabilityPool.claimCollateral(address(collateral), alice);
        assertEq(collateral.balanceOf(alice), aliceBefore + 1 ether);
    }

    function testFullOffsetAdvancesEpochAndPreservesRewardClaim() public {
        vm.prank(alice);
        stabilityPool.deposit(500 ether);
        collateral.mint(address(stabilityPool), 1 ether);

        stabilityPool.offset(address(collateral), 500 ether, 1 ether);
        assertEq(stabilityPool.totalDeposits(), 0);
        assertEq(stabilityPool.totalShares(), 0);
        assertEq(stabilityPool.currentEpoch(), 1);
        assertEq(stabilityPool.pendingCollateralGain(alice, address(collateral)), 1 ether);

        uint256 balanceBefore = collateral.balanceOf(alice);
        vm.prank(alice);
        stabilityPool.claimCollateral(address(collateral), alice);
        assertEq(collateral.balanceOf(alice), balanceBefore + 1 ether);
    }

    function testNewDepositorStartsAtCurrentCollateralIndex() public {
        vm.prank(alice);
        stabilityPool.deposit(1000 ether);
        collateral.mint(address(stabilityPool), 2 ether);
        stabilityPool.offset(address(collateral), 500 ether, 2 ether);

        vm.prank(bob);
        stabilityPool.deposit(1000 ether);

        assertEq(stabilityPool.pendingCollateralGain(alice, address(collateral)), 2 ether);
        assertEq(stabilityPool.pendingCollateralGain(bob, address(collateral)), 0);
    }

    function testVaultSurplusCanBeAccountedAndClaimed() public {
        uint256 vaultId = _openVault(alice, 5 ether);
        vaultManager.routeSurplus(vaultId, 2 ether);

        assertEq(surplusPool.surplusOf(alice, address(collateral)), 2 ether);
        assertEq(surplusPool.totalAccounted(address(collateral)), 2 ether);

        uint256 bobBefore = collateral.balanceOf(bob);
        vm.prank(alice);
        surplusPool.claim(address(collateral), 1 ether, bob);
        assertEq(collateral.balanceOf(bob), bobBefore + 1 ether);
        assertEq(surplusPool.surplusOf(alice, address(collateral)), 1 ether);

        vm.prank(alice);
        surplusPool.claim(address(collateral), type(uint256).max, alice);
        assertEq(surplusPool.surplusOf(alice, address(collateral)), 0);
        assertEq(surplusPool.totalAccounted(address(collateral)), 0);
    }
}
