// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVaultManager } from "../src/interfaces/IVelora.sol";
import { VeloraPortfolioLens } from "../src/lens/VeloraPortfolioLens.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract PortfolioLensTest is VeloraTestBase {
    function testAggregatesVaultsWithoutMutatingBalances() public {
        uint256 aliceVault = _openVault(alice, 10 ether);
        uint256 bobVault = _openVault(bob, 20 ether);
        _mintStable(alice, aliceVault, 1000 ether);

        VeloraPortfolioLens lens = new VeloraPortfolioLens(IVaultManager(address(vaultManager)));
        uint256[] memory ids = new uint256[](2);
        ids[0] = aliceVault;
        ids[1] = bobVault;
        VeloraPortfolioLens.VaultView[] memory views_ = lens.batchVaults(ids);

        assertEq(views_.length, 2);
        assertEq(views_[0].owner, alice);
        assertEq(views_[0].collateralAmount, 10 ether);
        assertEq(views_[0].collateralValue, 20_000 ether);
        assertGt(views_[0].debtValue, 1000 ether);
        assertEq(views_[1].owner, bob);
        assertEq(views_[1].collateralAmount, 20 ether);
        assertEq(views_[1].debtValue, 0);
        assertEq(debtLedger.accountedDebt(aliceVault), views_[0].debtValue);
    }

    function testRejectsZeroManager() public {
        vm.expectRevert(VeloraPortfolioLens.ManagerZero.selector);
        new VeloraPortfolioLens(IVaultManager(address(0)));
    }
}
