// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { FeeController } from "../src/core/FeeController.sol";
import { VeloraTestBase } from "./helpers/VeloraTestBase.sol";

contract FeeControllerTest is VeloraTestBase {
    function testDefaultCurvesIncreaseAcrossTheirKinks() public view {
        assertEq(fees.mintRate(0), 10);
        assertEq(fees.mintRate(8000), 30);
        assertEq(fees.mintRate(10_000), 130);

        assertEq(fees.redemptionRate(0), 15);
        assertEq(fees.redemptionRate(6000), 45);
        assertEq(fees.redemptionRate(10_000), 250);
    }

    function testQuotesExposeFeeNetAmountAndRate() public view {
        uint256 amount = 10_000 ether;
        (uint256 mintFee, uint256 mintNet, uint256 mintRate) = fees.quoteMint(amount, 8000);
        (uint256 redeemFee, uint256 redeemNet, uint256 redeemRate) =
            fees.quoteRedemption(amount, 6000);

        assertEq(mintRate, 30);
        assertEq(mintFee, 30 ether);
        assertEq(mintNet + mintFee, amount);
        assertEq(redeemRate, 45);
        assertEq(redeemFee, 45 ether);
        assertEq(redeemNet + redeemFee, amount);
    }

    function testAdminCanConfigureCurvesAndCaps() public {
        fees.setMintCurve(
            FeeController.FeeCurve({
                baseRateBps: 20,
                kinkBps: 5000,
                preKinkSlopeBps: 100,
                postKinkSlopeBps: 200,
                maxRateBps: 150
            })
        );
        assertEq(fees.mintRate(2500), 45);
        assertEq(fees.mintRate(7500), 120);

        fees.setFeeCaps(2 ether, 3 ether);
        assertEq(fees.mintFee(100_000 ether, 10_000), 2 ether);
        assertEq(fees.redemptionFee(100_000 ether, 10_000), 3 ether);
    }

    function testFactorsAboveOneHundredPercentAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(FeeController.FeeFactorOutOfRange.selector, 10_001));
        fees.mintRate(10_001);
    }

    function testFuzzFeeQuotesStayWithinConfiguredRates(uint128 amountSeed, uint16 factorSeed)
        public
        view
    {
        uint256 amount = bound(uint256(amountSeed), 1, 1_000_000 ether);
        uint256 factor = bound(uint256(factorSeed), 0, 10_000);

        (uint256 mintFee, uint256 mintNet, uint256 mintRate) = fees.quoteMint(amount, factor);
        (uint256 redeemFee, uint256 redeemNet, uint256 redeemRate) =
            fees.quoteRedemption(amount, factor);

        assertLe(mintRate, 150);
        assertLe(redeemRate, 250);
        assertEq(mintNet + mintFee, amount);
        assertEq(redeemNet + redeemFee, amount);
        assertEq(mintFee, ((amount * mintRate) + 9999) / 10_000);
        assertEq(redeemFee, ((amount * redeemRate) + 9999) / 10_000);
    }
}
