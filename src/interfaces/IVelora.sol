// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    CollateralConfig,
    DebtPosition,
    PriceData,
    RiskSnapshot,
    VaultData
} from "../types/VeloraTypes.sol";

/// @notice Minimal ERC-20 interface used by protocol components.
interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Minting and burning surface of the Velora stablecoin.
interface IVeloraUSD is IERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/// @notice Source of canonical collateral prices.
interface IPriceOracle {
    function getPrice(bytes32 oracleId) external view returns (uint256 price);
    function getPriceData(bytes32 oracleId) external view returns (PriceData memory data);
}

/// @notice Registry and valuation surface for accepted collateral.
interface ICollateralRegistry {
    function getConfig(address collateralToken)
        external
        view
        returns (CollateralConfig memory config);

    function collateralValue(address collateralToken, uint256 tokenAmount)
        external
        view
        returns (uint256 value);

    function tokenAmountForValue(address collateralToken, uint256 value)
        external
        view
        returns (uint256 tokenAmount);

    function tokenAmountForValue(address collateralToken, uint256 value, bool roundUp)
        external
        view
        returns (uint256 tokenAmount);
}

/// @notice Share ledger that coordinates aggregate and vault-level debt.
interface IDebtLedger {
    function totalDebt() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function totalPendingRepayments() external view returns (uint256);
    function totalBadDebt() external view returns (uint256);
    function badDebtOf(uint256 vaultId) external view returns (uint256);
    function position(uint256 vaultId) external view returns (DebtPosition memory debtPosition);
    function quotedDebt(uint256 vaultId) external view returns (uint256);
    function accountedDebt(uint256 vaultId) external view returns (uint256);

    function increaseDebt(uint256 vaultId, uint256 amount) external returns (uint256 sharesIssued);
    function recordRepayment(uint256 vaultId, uint256 amount)
        external
        returns (uint256 amountRecorded);
    function synchronize(uint256 vaultId)
        external
        returns (uint256 sharesRemoved, uint256 repayment);
    function repayAndSynchronize(uint256 vaultId, uint256 amount)
        external
        returns (uint256 sharesRemoved);
    function recognizeBadDebt(uint256 vaultId) external returns (uint256 amount);
    function coverBadDebt(uint256 vaultId, uint256 amount) external;
}

/// @notice Vault ownership, inspection, and privileged settlement surface.
interface IVaultManager {
    function ownerOf(uint256 vaultId) external view returns (address owner);
    function getVault(uint256 vaultId) external view returns (VaultData memory vault);
    function riskSnapshot(uint256 vaultId) external view returns (RiskSnapshot memory snapshot);
    function accountedDebt(uint256 vaultId) external view returns (uint256 debt);

    function executeLiquidation(
        uint256 vaultId,
        uint256 debtToRepay,
        uint256 collateralToSeize,
        address payer,
        address recipient
    ) external returns (uint256 actualCollateral);

    function executeRedemption(
        uint256 vaultId,
        uint256 stableAmount,
        uint256 minimumCollateral,
        address stablePayer,
        address recipient,
        uint256 activityBps
    ) external returns (uint256 collateralOut);

    function recognizeBadDebt(uint256 vaultId) external returns (uint256 amount);
    function settleBadDebt(uint256 vaultId, uint256 amount) external;
}

/// @notice Read-only fee quotes used by issuance and redemption flows.
interface IFeeController {
    function mintFee(uint256 debtAmount, uint256 utilizationBps)
        external
        view
        returns (uint256 feeAmount);
    function redemptionFee(uint256 stableAmount, uint256 activityBps)
        external
        view
        returns (uint256 feeAmount);
}

/// @notice Custody accounting for collateral left after a terminal settlement.
interface ISurplusPool {
    function accountSurplus(address account, address collateralToken, uint256 amount) external;
}

/// @notice Stablecoin reserve that absorbs liquidated debt in exchange for collateral.
interface IStabilityPool {
    function totalDeposits() external view returns (uint256);

    function offset(address collateralToken, uint256 debtToOffset, uint256 collateralToAdd)
        external
        returns (uint256 debtOffset);
}
