// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RedemptionQueue } from "../src/modules/RedemptionQueue.sol";
import { RedemptionRequest, RedemptionStatus } from "../src/types/VeloraTypes.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract RedemptionTest is VeloraTestBase {
    RedemptionQueue internal redemptionQueue;
    uint256 internal vaultId;

    function setUp() public override {
        super.setUp();
        redemptionQueue = new RedemptionQueue(address(this), vaultManager, registry);
        vaultManager.grantRole(vaultManager.REDEMPTION_ROLE(), address(redemptionQueue));

        vm.prank(alice);
        stablecoin.approve(address(redemptionQueue), type(uint256).max);
        vaultId = _openVault(alice, 10 ether);
        _mintStable(alice, vaultId, 5000 ether);
    }

    function testQueuedRedemptionExecutesAfterDelay() public {
        uint256 debtBefore = debtLedger.accountedDebt(vaultId);
        uint256 supplyBefore = stablecoin.totalSupply();
        uint48 deadline = uint48(block.timestamp + 2 days);

        vm.prank(alice);
        uint256 requestId =
            redemptionQueue.requestRedemption(vaultId, 1000 ether, 0.49 ether, bob, deadline);
        RedemptionRequest memory pending = redemptionQueue.getRequest(requestId);
        assertEq(uint256(pending.status), uint256(RedemptionStatus.Pending));
        assertEq(pending.requester, alice);
        assertEq(pending.receiver, bob);
        assertEq(redemptionQueue.lockedStablecoin(), 1000 ether);

        vm.expectPartialRevert(RedemptionQueue.RedemptionDelayActive.selector);
        redemptionQueue.executeRedemption(requestId);

        vm.warp(block.timestamp + redemptionQueue.executionDelay());
        uint256 bobCollateralBefore = collateral.balanceOf(bob);
        uint256 collateralOut = redemptionQueue.executeRedemption(requestId);

        RedemptionRequest memory executed = redemptionQueue.getRequest(requestId);
        assertEq(uint256(executed.status), uint256(RedemptionStatus.Executed));
        assertEq(executed.collateralOut, collateralOut);
        assertEq(redemptionQueue.lockedStablecoin(), 0);
        assertEq(collateral.balanceOf(bob), bobCollateralBefore + collateralOut);
        assertEq(stablecoin.totalSupply(), supplyBefore - 1000 ether);
        assertEq(debtLedger.accountedDebt(vaultId), debtBefore - 1000 ether);
        assertGt(redemptionQueue.redemptionActivityBps(), 0);
    }

    function testRequesterCanCancelAndRecoverLockedStablecoin() public {
        uint256 balanceBefore = stablecoin.balanceOf(alice);
        vm.prank(alice);
        uint256 requestId = redemptionQueue.requestRedemption(
            vaultId, 500 ether, 0, alice, uint48(block.timestamp + 1 days)
        );
        assertEq(stablecoin.balanceOf(alice), balanceBefore - 500 ether);

        vm.prank(alice);
        redemptionQueue.cancelRedemption(requestId);

        RedemptionRequest memory request = redemptionQueue.getRequest(requestId);
        assertEq(uint256(request.status), uint256(RedemptionStatus.Cancelled));
        assertEq(stablecoin.balanceOf(alice), balanceBefore);
        assertEq(redemptionQueue.lockedStablecoin(), 0);
    }

    function testExpiredRequestCanBeRefunded() public {
        uint256 balanceBefore = stablecoin.balanceOf(alice);
        uint48 deadline = uint48(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 requestId =
            redemptionQueue.requestRedemption(vaultId, 400 ether, 0, alice, deadline);

        vm.warp(uint256(deadline) + 1);
        vm.prank(bob);
        redemptionQueue.expireRedemption(requestId);

        RedemptionRequest memory request = redemptionQueue.getRequest(requestId);
        assertEq(uint256(request.status), uint256(RedemptionStatus.Expired));
        assertEq(stablecoin.balanceOf(alice), balanceBefore);
        assertEq(redemptionQueue.lockedStablecoin(), 0);
    }
}
