// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Lifecycle states used by collateral vaults.
enum VaultStatus {
    None,
    Active,
    Frozen,
    Liquidating,
    Closed
}

/// @notice Lifecycle states used by asynchronous redemption requests.
enum RedemptionStatus {
    None,
    Pending,
    Executed,
    Cancelled,
    Expired
}

/// @notice Risk and capacity parameters for one collateral token.
/// @dev Debt limits use 18-decimal stablecoin units, `depositCap` uses raw token units,
///      and ratios use basis points.
struct CollateralConfig {
    bool enabled;
    uint8 decimals;
    bytes32 oracleId;
    uint16 minCollateralRatioBps;
    uint16 liquidationRatioBps;
    uint16 liquidationBonusBps;
    uint16 redemptionFeeBps;
    uint256 debtCeiling;
    uint256 depositCap;
    uint256 minDebt;
}

/// @notice Canonical oracle observation consumed by the protocol.
/// @dev `price` is denominated in 18-decimal stablecoin units per whole token.
struct PriceData {
    uint256 price;
    uint48 updatedAt;
    uint48 validUntil;
    uint80 roundId;
}

/// @notice Persistent collateral-side state for a vault.
struct VaultData {
    address owner;
    address collateralToken;
    uint256 collateralAmount;
    VaultStatus status;
    uint48 openedAt;
    uint48 lastTouchedAt;
}

/// @notice Share-based debt state associated with one vault.
struct DebtPosition {
    uint256 shares;
    uint256 pendingRepayment;
    uint48 lastSync;
}

/// @notice Point-in-time risk view for a vault.
struct RiskSnapshot {
    uint256 collateralValue;
    uint256 debtValue;
    uint256 ratioBps;
    bool liquidatable;
}

/// @notice Deterministic amounts produced for a liquidation.
struct LiquidationQuote {
    uint256 requestedDebt;
    uint256 debtCovered;
    uint256 collateralSeized;
    uint256 bonusCollateral;
    uint256 remainingDebt;
    uint256 remainingCollateral;
    bool closesVault;
}

/// @notice Stored parameters and settlement result for a redemption request.
struct RedemptionRequest {
    uint256 id;
    uint256 vaultId;
    address requester;
    address receiver;
    address collateralToken;
    uint256 stableAmount;
    uint256 minCollateralOut;
    uint256 collateralOut;
    uint256 feeAmount;
    RedemptionStatus status;
    uint48 createdAt;
    uint48 executableAt;
    uint48 deadline;
}
