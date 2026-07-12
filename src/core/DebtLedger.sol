// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { DebtPosition } from "../types/VeloraTypes.sol";
import { FullMath } from "../libraries/FullMath.sol";

/// @title DebtLedger
/// @notice Canonical aggregate and vault-level debt accounting for Velora.
/// @dev Debt is represented by fungible shares. Repayments are admitted globally and
///      materialized against an individual vault during a synchronization checkpoint.
contract DebtLedger is ProtocolAccess {
    using FullMath for uint256;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public totalDebt;
    uint256 public totalShares;
    uint256 public totalPendingRepayments;
    uint256 public totalBadDebt;

    mapping(uint256 vaultId => DebtPosition) private _positions;
    mapping(uint256 vaultId => uint256 amount) public badDebtOf;

    error AmountZero();
    error DebtTooLow(uint256 available, uint256 requested);
    error ShareOverflow();
    error InconsistentLedger();
    error NoBadDebt(uint256 vaultId);

    event DebtIncreased(
        uint256 indexed vaultId,
        uint256 amount,
        uint256 shares,
        uint256 totalDebt,
        uint256 totalShares
    );
    event RepaymentRecorded(
        uint256 indexed vaultId, uint256 amount, uint256 pendingForVault, uint256 totalDebt
    );
    event DebtSynchronized(
        uint256 indexed vaultId, uint256 repayment, uint256 sharesRemoved, uint256 remainingShares
    );
    event BadDebtRecognized(uint256 indexed vaultId, uint256 amount, uint256 totalBadDebt);
    event BadDebtCovered(uint256 indexed vaultId, uint256 amount, uint256 remainingBadDebt);
    constructor(address admin) ProtocolAccess(admin) { }

    /// @notice Returns the stored debt position for a vault.
    function position(uint256 vaultId) external view returns (DebtPosition memory) {
        return _positions[vaultId];
    }

    /// @notice Returns the debt represented by a vault in the current aggregate view.
    function quotedDebt(uint256 vaultId) public view returns (uint256) {
        DebtPosition storage debtPosition = _positions[vaultId];
        if (debtPosition.shares == 0 || totalShares == 0) return 0;

        uint256 representedDebt = FullMath.mulDivUp(debtPosition.shares, totalDebt, totalShares);
        if (debtPosition.pendingRepayment >= representedDebt) return 0;
        return representedDebt - debtPosition.pendingRepayment;
    }

    /// @notice Returns debt after attributing all admitted repayments to their source vaults.
    function accountedDebt(uint256 vaultId) public view returns (uint256) {
        DebtPosition storage debtPosition = _positions[vaultId];
        if (debtPosition.shares == 0 || totalShares == 0) return 0;

        uint256 grossDebt = totalDebt + totalPendingRepayments;
        uint256 vaultGrossDebt = FullMath.mulDivUp(debtPosition.shares, grossDebt, totalShares);

        if (debtPosition.pendingRepayment >= vaultGrossDebt) return 0;
        return vaultGrossDebt - debtPosition.pendingRepayment;
    }

    /// @notice Creates debt shares for a vault.
    function increaseDebt(uint256 vaultId, uint256 amount)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 sharesCreated)
    {
        if (amount == 0) revert AmountZero();
        if (_positions[vaultId].pendingRepayment != 0) {
            _synchronize(vaultId);
        }

        if (totalShares == 0 || totalDebt == 0) {
            sharesCreated = amount;
        } else {
            sharesCreated = FullMath.mulDivUp(amount, totalShares, totalDebt);
        }
        if (sharesCreated == 0) revert ShareOverflow();

        DebtPosition storage debtPosition = _positions[vaultId];
        debtPosition.shares += sharesCreated;
        debtPosition.lastSync = uint40(block.timestamp);
        totalShares += sharesCreated;
        totalDebt += amount;

        emit DebtIncreased(vaultId, amount, sharesCreated, totalDebt, totalShares);
    }

    /// @notice Admits a repayment and stages its vault-level share adjustment.
    function recordRepayment(uint256 vaultId, uint256 amount)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 admitted)
    {
        if (amount == 0) revert AmountZero();
        uint256 available = accountedDebt(vaultId);
        if (amount > available) revert DebtTooLow(available, amount);
        if (amount > totalDebt) revert InconsistentLedger();

        DebtPosition storage debtPosition = _positions[vaultId];
        debtPosition.pendingRepayment += amount;
        totalPendingRepayments += amount;
        totalDebt -= amount;
        admitted = amount;

        emit RepaymentRecorded(vaultId, amount, debtPosition.pendingRepayment, totalDebt);
    }

    /// @notice Applies a vault's staged repayment to its debt shares.
    function synchronize(uint256 vaultId)
        external
        returns (uint256 sharesRemoved, uint256 repayment)
    {
        return _synchronize(vaultId);
    }

    /// @notice Repays and synchronizes debt in one manager operation.
    function repayAndSynchronize(uint256 vaultId, uint256 amount)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 sharesRemoved)
    {
        if (amount == 0) revert AmountZero();
        uint256 available = accountedDebt(vaultId);
        if (amount > available) revert DebtTooLow(available, amount);
        if (amount > totalDebt) revert InconsistentLedger();

        DebtPosition storage debtPosition = _positions[vaultId];
        debtPosition.pendingRepayment += amount;
        totalPendingRepayments += amount;
        totalDebt -= amount;

        emit RepaymentRecorded(vaultId, amount, debtPosition.pendingRepayment, totalDebt);
        (sharesRemoved,) = _synchronize(vaultId);
    }

    /// @notice Removes debt from an exhausted vault and records it for recapitalization.
    function recognizeBadDebt(uint256 vaultId)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 amount)
    {
        _synchronize(vaultId);
        DebtPosition storage debtPosition = _positions[vaultId];
        uint256 shares = debtPosition.shares;
        if (shares == 0 || totalShares == 0) revert NoBadDebt(vaultId);

        amount = FullMath.mulDiv(shares, totalDebt, totalShares);
        if (amount == 0) revert NoBadDebt(vaultId);
        if (amount > totalDebt) amount = totalDebt;

        debtPosition.shares = 0;
        debtPosition.lastSync = uint40(block.timestamp);
        totalShares -= shares;
        totalDebt -= amount;
        badDebtOf[vaultId] += amount;
        totalBadDebt += amount;
        emit BadDebtRecognized(vaultId, amount, totalBadDebt);
    }

    /// @notice Reduces recorded bad debt after an equivalent stablecoin recapitalization.
    function coverBadDebt(uint256 vaultId, uint256 amount) external onlyRole(MANAGER_ROLE) {
        uint256 outstanding = badDebtOf[vaultId];
        if (amount == 0 || amount > outstanding) revert NoBadDebt(vaultId);
        badDebtOf[vaultId] = outstanding - amount;
        totalBadDebt -= amount;
        emit BadDebtCovered(vaultId, amount, outstanding - amount);
    }

    /// @notice Checks aggregate relationships used by monitoring and invariant suites.
    function ledgerInvariant()
        external
        view
        returns (bool debtSharesConsistent, bool emptyStateConsistent)
    {
        debtSharesConsistent = totalDebt + totalPendingRepayments == totalShares;
        emptyStateConsistent = totalShares != 0 || (totalDebt == 0 && totalPendingRepayments == 0);
    }

    function _synchronize(uint256 vaultId)
        internal
        returns (uint256 sharesRemoved, uint256 repayment)
    {
        DebtPosition storage debtPosition = _positions[vaultId];
        repayment = debtPosition.pendingRepayment;
        if (repayment == 0) return (0, 0);
        if (totalShares == 0) revert InconsistentLedger();

        uint256 grossDebt = totalDebt + totalPendingRepayments;
        uint256 vaultGrossDebt = FullMath.mulDivUp(debtPosition.shares, grossDebt, totalShares);

        if (repayment >= vaultGrossDebt) {
            sharesRemoved = debtPosition.shares;
        } else {
            sharesRemoved = FullMath.mulDiv(repayment, totalShares, grossDebt);
            if (sharesRemoved == 0) sharesRemoved = 1;
            if (sharesRemoved > debtPosition.shares) sharesRemoved = debtPosition.shares;
        }

        debtPosition.shares -= sharesRemoved;
        debtPosition.pendingRepayment = 0;
        debtPosition.lastSync = uint40(block.timestamp);
        totalShares -= sharesRemoved;
        totalPendingRepayments -= repayment;

        if (totalShares == 0 && totalDebt != 0) revert InconsistentLedger();

        emit DebtSynchronized(vaultId, repayment, sharesRemoved, debtPosition.shares);
    }
}
