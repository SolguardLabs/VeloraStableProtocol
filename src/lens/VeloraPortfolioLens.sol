// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IVaultManager } from "../interfaces/IVelora.sol";
import { RiskSnapshot, VaultData, VaultStatus } from "../types/VeloraTypes.sol";

/// @title VeloraPortfolioLens
/// @notice Aggregates point-in-time vault information without writing protocol state.
contract VeloraPortfolioLens {
    IVaultManager public immutable manager;

    struct VaultView {
        uint256 vaultId;
        address owner;
        address collateralToken;
        uint256 collateralAmount;
        VaultStatus status;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 ratioBps;
        bool liquidatable;
    }

    error ManagerZero();

    constructor(IVaultManager manager_) {
        if (address(manager_) == address(0)) revert ManagerZero();
        manager = manager_;
    }

    function vault(uint256 vaultId) public view returns (VaultView memory view_) {
        VaultData memory data = manager.getVault(vaultId);
        RiskSnapshot memory risk = manager.riskSnapshot(vaultId);
        view_ = VaultView({
            vaultId: vaultId,
            owner: data.owner,
            collateralToken: data.collateralToken,
            collateralAmount: data.collateralAmount,
            status: data.status,
            collateralValue: risk.collateralValue,
            debtValue: risk.debtValue,
            ratioBps: risk.ratioBps,
            liquidatable: risk.liquidatable
        });
    }

    /// @dev The caller should keep batches within the chain's practical gas/RPC limits.
    function batchVaults(uint256[] calldata ids) external view returns (VaultView[] memory views_) {
        views_ = new VaultView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            views_[i] = vault(ids[i]);
        }
    }
}
