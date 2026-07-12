// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { VaultManager } from "../src/core/VaultManager.sol";
import { RiskSnapshot, VaultData, VaultStatus } from "../src/types/VeloraTypes.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract VaultLifecycleTest is VeloraTestBase {
    function testOpenDepositMintRepayWithdrawAndClose() public {
        uint256 initialCollateral = collateral.balanceOf(alice);
        uint256 vaultId = _openVault(alice, 10 ether);

        VaultData memory opened = vaultManager.getVault(vaultId);
        assertEq(opened.owner, alice);
        assertEq(opened.collateralToken, address(collateral));
        assertEq(opened.collateralAmount, 10 ether);
        assertEq(uint256(opened.status), uint256(VaultStatus.Active));

        vm.prank(alice);
        vaultManager.depositCollateral(vaultId, 2 ether);
        assertEq(vaultManager.getVault(vaultId).collateralAmount, 12 ether);

        uint256 fee = _mintStable(alice, vaultId, 5000 ether);
        assertGt(fee, 0);
        assertEq(stablecoin.balanceOf(alice), 5000 ether);
        assertEq(stablecoin.balanceOf(treasury), fee);
        assertEq(debtLedger.accountedDebt(vaultId), 5000 ether + fee);

        vm.prank(alice);
        vaultManager.repayDebt(vaultId, 1000 ether);
        assertEq(debtLedger.accountedDebt(vaultId), 4000 ether + fee);

        vm.prank(alice);
        vaultManager.withdrawCollateral(vaultId, 1 ether, alice);
        assertEq(vaultManager.getVault(vaultId).collateralAmount, 11 ether);

        _repayAll(alice, vaultId);
        assertEq(debtLedger.accountedDebt(vaultId), 0);

        vm.prank(alice);
        vaultManager.closeVault(vaultId, alice);

        VaultData memory closed = vaultManager.getVault(vaultId);
        assertEq(closed.collateralAmount, 0);
        assertEq(uint256(closed.status), uint256(VaultStatus.Closed));
        assertEq(collateral.balanceOf(alice), initialCollateral);
        assertEq(vaultManager.totalCollateral(address(collateral)), 0);
        assertEq(debtLedger.totalDebt(), 0);
        assertEq(debtLedger.totalShares(), 0);
    }

    function testCombinedAdjustmentRemainsWellCollateralized() public {
        uint256 vaultId = _openVault(alice, 30 ether);
        uint256 bobCollateralBefore = collateral.balanceOf(bob);

        VaultManager.Adjustment memory adjustment = VaultManager.Adjustment({
            collateralDeposit: 5 ether,
            collateralWithdrawal: 2 ether,
            debtIncrease: 1000 ether,
            debtRepayment: 0,
            collateralRecipient: bob,
            debtRecipient: bob
        });

        vm.prank(alice);
        vaultManager.adjustVault(vaultId, adjustment);

        VaultData memory vault = vaultManager.getVault(vaultId);
        RiskSnapshot memory risk = vaultManager.riskSnapshot(vaultId);
        assertEq(vault.collateralAmount, 33 ether);
        assertEq(collateral.balanceOf(bob), bobCollateralBefore + 2 ether);
        assertEq(stablecoin.balanceOf(bob), 1000 ether);
        assertGe(risk.ratioBps, 15_000);
        assertFalse(risk.liquidatable);
    }

    function testOwnerCanDelegateRoutineVaultManagement() public {
        uint256 vaultId = _openVault(alice, 15 ether);

        vm.prank(alice);
        vaultManager.setVaultDelegate(vaultId, bob);
        assertTrue(vaultManager.isVaultController(vaultId, bob));

        vm.prank(bob);
        vaultManager.mintStablecoin(vaultId, 1000 ether, bob);
        vm.prank(bob);
        vaultManager.withdrawCollateral(vaultId, 1 ether, bob);

        assertEq(stablecoin.balanceOf(bob), 1000 ether);
        assertEq(vaultManager.getVault(vaultId).collateralAmount, 14 ether);

        vm.prank(alice);
        vaultManager.setVaultDelegate(vaultId, address(0));
        assertFalse(vaultManager.isVaultController(vaultId, bob));
        assertTrue(vaultManager.isVaultController(vaultId, alice));
    }

    function testFuzzHealthyMintWithinConservativeBounds(uint96 collateralSeed, uint96 mintSeed)
        public
    {
        uint256 collateralAmount = bound(uint256(collateralSeed), 2 ether, 100 ether);
        uint256 collateralValue = collateralAmount * 2000;
        uint256 maximumMint = collateralValue / 4;
        uint256 mintAmount = bound(uint256(mintSeed), MINIMUM_DEBT, maximumMint);

        uint256 vaultId = _openVault(alice, collateralAmount);
        _mintStable(alice, vaultId, mintAmount);

        RiskSnapshot memory risk = vaultManager.riskSnapshot(vaultId);
        assertEq(stablecoin.balanceOf(alice), mintAmount);
        assertGe(risk.ratioBps, 15_000);
        assertFalse(risk.liquidatable);
    }
}
