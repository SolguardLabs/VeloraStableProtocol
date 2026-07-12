// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import {
    IERC20,
    IVeloraUSD,
    ICollateralRegistry,
    IFeeController,
    ISurplusPool
} from "../interfaces/IVelora.sol";
import { VaultStatus, CollateralConfig, VaultData, RiskSnapshot } from "../types/VeloraTypes.sol";
import { DebtLedger } from "./DebtLedger.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title VaultManager
/// @notice Custodies collateral and coordinates issuance, repayment, redemption, and liquidation.
contract VaultManager is ProtocolAccess {
    using SafeTransferLib for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant LIQUIDATION_ROLE = keccak256("LIQUIDATION_ROLE");
    bytes32 public constant REDEMPTION_ROLE = keccak256("REDEMPTION_ROLE");

    uint256 public constant BPS = 10_000;

    struct Adjustment {
        uint256 collateralDeposit;
        uint256 collateralWithdrawal;
        uint256 debtIncrease;
        uint256 debtRepayment;
        address collateralRecipient;
        address debtRecipient;
    }

    IVeloraUSD public immutable stablecoin;
    DebtLedger public immutable debtLedger;
    ICollateralRegistry public immutable collateralRegistry;
    IFeeController public feeController;

    address public treasury;
    address public surplusPool;
    uint256 public nextVaultId = 1;
    bool public paused;

    mapping(uint256 vaultId => VaultData) private _vaults;
    mapping(uint256 vaultId => address) public vaultDelegate;
    mapping(address token => uint256) public totalCollateral;
    mapping(address token => uint256) public issuedDebt;
    mapping(address token => uint256) public protocolCollateralFees;

    uint256 private _entered = 1;

    error AmountZero();
    error AddressZero();
    error ProtocolPaused();
    error ReentrantCall();
    error VaultNotFound(uint256 vaultId);
    error VaultNotActive(uint256 vaultId);
    error NotVaultController(uint256 vaultId, address caller);
    error UnsupportedCollateral(address token);
    error DepositCapExceeded(address token, uint256 projected, uint256 cap);
    error DebtCeilingExceeded(address token, uint256 projected, uint256 ceiling);
    error InsufficientCollateral(uint256 available, uint256 requested);
    error CollateralRatioTooLow(uint256 ratioBps, uint256 requiredBps);
    error DebtBelowMinimum(uint256 debt, uint256 minimum);
    error OutstandingDebt(uint256 debt);
    error HealthyVault(uint256 ratioBps, uint256 liquidationRatioBps);
    error InvalidAdjustment();
    error SlippageExceeded(uint256 output, uint256 minimum);
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error IssuedDebtInconsistent(address token, uint256 issued, uint256 reduction);

    event VaultOpened(
        uint256 indexed vaultId,
        address indexed owner,
        address indexed collateralToken,
        uint256 collateralAmount
    );
    event VaultTransferred(
        uint256 indexed vaultId, address indexed previousOwner, address indexed newOwner
    );
    event VaultDelegateUpdated(uint256 indexed vaultId, address indexed delegate);
    event CollateralDeposited(
        uint256 indexed vaultId, address indexed payer, uint256 amount, uint256 balance
    );
    event CollateralWithdrawn(
        uint256 indexed vaultId, address indexed recipient, uint256 amount, uint256 balance
    );
    event StablecoinMinted(
        uint256 indexed vaultId,
        address indexed recipient,
        uint256 amount,
        uint256 fee,
        uint256 debt
    );
    event DebtRepaid(
        uint256 indexed vaultId, address indexed payer, uint256 amount, bool synchronized
    );
    event VaultAdjusted(
        uint256 indexed vaultId,
        int256 collateralDelta,
        int256 debtDelta,
        uint256 resultingCollateral,
        uint256 resultingDebt
    );
    event VaultClosed(uint256 indexed vaultId, address indexed owner);
    event LiquidationExecuted(
        uint256 indexed vaultId,
        address indexed payer,
        address indexed recipient,
        uint256 debtRepaid,
        uint256 collateralSeized
    );
    event RedemptionExecuted(
        uint256 indexed vaultId,
        address indexed recipient,
        uint256 debtRepaid,
        uint256 collateralSent,
        uint256 collateralFee
    );
    event BadDebtRecognized(uint256 indexed vaultId, uint256 amount);
    event BadDebtSettled(uint256 indexed vaultId, address indexed payer, uint256 amount);
    event PauseUpdated(bool paused);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event FeeControllerUpdated(address indexed previousController, address indexed newController);
    event SurplusPoolUpdated(address indexed previousPool, address indexed newPool);

    modifier nonReentrant() {
        if (_entered != 1) revert ReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    constructor(
        address admin,
        IVeloraUSD stablecoin_,
        DebtLedger debtLedger_,
        ICollateralRegistry collateralRegistry_,
        IFeeController feeController_,
        address treasury_
    ) ProtocolAccess(admin) {
        if (
            address(stablecoin_) == address(0) || address(debtLedger_) == address(0)
                || address(collateralRegistry_) == address(0)
                || address(feeController_) == address(0) || treasury_ == address(0)
        ) revert AddressZero();

        stablecoin = stablecoin_;
        debtLedger = debtLedger_;
        collateralRegistry = collateralRegistry_;
        feeController = feeController_;
        treasury = treasury_;
    }

    /// @notice Opens a vault and optionally supplies its initial collateral.
    function openVault(address collateralToken, uint256 collateralAmount)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 vaultId)
    {
        CollateralConfig memory config = collateralRegistry.getConfig(collateralToken);
        if (!config.enabled) revert UnsupportedCollateral(collateralToken);

        vaultId = nextVaultId++;
        VaultData storage vault = _vaults[vaultId];
        vault.owner = msg.sender;
        vault.collateralToken = collateralToken;
        vault.status = VaultStatus.Active;
        vault.openedAt = uint40(block.timestamp);
        vault.lastTouchedAt = uint40(block.timestamp);

        if (collateralAmount != 0) {
            _deposit(vaultId, vault, msg.sender, collateralAmount, config);
        }

        emit VaultOpened(vaultId, msg.sender, collateralToken, collateralAmount);
    }

    /// @notice Returns vault custody and lifecycle data.
    function getVault(uint256 vaultId) external view returns (VaultData memory) {
        VaultData memory vault = _vaults[vaultId];
        if (vault.status == VaultStatus.None) revert VaultNotFound(vaultId);
        return vault;
    }

    /// @notice Returns the current owner of a vault.
    function ownerOf(uint256 vaultId) public view returns (address) {
        address owner = _vaults[vaultId].owner;
        if (owner == address(0)) revert VaultNotFound(vaultId);
        return owner;
    }

    /// @notice Returns whether an account may manage a vault.
    function isVaultController(uint256 vaultId, address account) public view returns (bool) {
        VaultData storage vault = _vaults[vaultId];
        return vault.owner == account || vaultDelegate[vaultId] == account;
    }

    /// @notice Assigns an operational delegate without transferring vault ownership.
    function setVaultDelegate(uint256 vaultId, address delegate) external {
        if (_vaults[vaultId].owner != msg.sender) {
            revert NotVaultController(vaultId, msg.sender);
        }
        vaultDelegate[vaultId] = delegate;
        emit VaultDelegateUpdated(vaultId, delegate);
    }

    /// @notice Transfers a debt-bearing vault as a single position.
    function transferVault(uint256 vaultId, address newOwner) external whenNotPaused {
        if (newOwner == address(0)) revert AddressZero();
        VaultData storage vault = _activeVault(vaultId);
        if (vault.owner != msg.sender) revert NotVaultController(vaultId, msg.sender);

        address previousOwner = vault.owner;
        vault.owner = newOwner;
        vaultDelegate[vaultId] = address(0);
        vault.lastTouchedAt = uint40(block.timestamp);
        emit VaultTransferred(vaultId, previousOwner, newOwner);
    }

    /// @notice Adds collateral to an active vault.
    function depositCollateral(uint256 vaultId, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        VaultData storage vault = _activeVault(vaultId);
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        _deposit(vaultId, vault, msg.sender, amount, config);
    }

    /// @notice Withdraws collateral while preserving the configured issuance ratio.
    function withdrawCollateral(uint256 vaultId, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert AmountZero();
        if (recipient == address(0)) revert AddressZero();
        VaultData storage vault = _controlledActiveVault(vaultId);

        _withdraw(vaultId, vault, amount, recipient, debtLedger.quotedDebt(vaultId));
    }

    /// @notice Issues stablecoin against an active vault.
    function mintStablecoin(uint256 vaultId, uint256 amount, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 fee)
    {
        if (amount == 0) revert AmountZero();
        if (recipient == address(0)) revert AddressZero();
        VaultData storage vault = _controlledActiveVault(vaultId);
        fee = _mint(vaultId, vault, amount, recipient);
    }

    /// @notice Burns stablecoin and immediately checkpoints the vault debt shares.
    function repayDebt(uint256 vaultId, uint256 amount)
        external
        nonReentrant
        returns (uint256 repaid)
    {
        VaultData storage vault = _activeVault(vaultId);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        repaid = amount == type(uint256).max ? debt : amount;
        if (repaid == 0) revert AmountZero();
        if (repaid > debt) revert OutstandingDebt(debt);

        stablecoin.burnFrom(msg.sender, repaid);
        debtLedger.repayAndSynchronize(vaultId, repaid);
        _reduceIssuedDebt(vault.collateralToken, repaid);
        vault.lastTouchedAt = uint40(block.timestamp);

        _validateDebtFloor(vault.collateralToken, debtLedger.accountedDebt(vaultId));
        emit DebtRepaid(vaultId, msg.sender, repaid, true);
    }

    /// @notice Applies a combined collateral and debt adjustment in one transaction.
    function adjustVault(uint256 vaultId, Adjustment calldata adjustment)
        external
        nonReentrant
        whenNotPaused
    {
        VaultData storage vault = _controlledActiveVault(vaultId);
        if (adjustment.debtIncrease != 0 && adjustment.debtRepayment != 0) {
            revert InvalidAdjustment();
        }
        if (
            adjustment.collateralDeposit == 0 && adjustment.collateralWithdrawal == 0
                && adjustment.debtIncrease == 0 && adjustment.debtRepayment == 0
        ) revert InvalidAdjustment();

        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        uint256 fee;

        if (adjustment.collateralDeposit != 0) {
            _deposit(vaultId, vault, msg.sender, adjustment.collateralDeposit, config);
        }

        if (adjustment.debtRepayment != 0) {
            uint256 debt = debtLedger.accountedDebt(vaultId);
            if (adjustment.debtRepayment > debt) revert OutstandingDebt(debt);
            stablecoin.burnFrom(msg.sender, adjustment.debtRepayment);
            debtLedger.recordRepayment(vaultId, adjustment.debtRepayment);
            _reduceIssuedDebt(vault.collateralToken, adjustment.debtRepayment);
        }

        if (adjustment.debtIncrease != 0) {
            address debtRecipient =
                adjustment.debtRecipient == address(0) ? msg.sender : adjustment.debtRecipient;
            fee = _mint(vaultId, vault, adjustment.debtIncrease, debtRecipient);
        }

        if (adjustment.collateralWithdrawal != 0) {
            address collateralRecipient = adjustment.collateralRecipient == address(0)
                ? msg.sender
                : adjustment.collateralRecipient;
            _withdraw(
                vaultId,
                vault,
                adjustment.collateralWithdrawal,
                collateralRecipient,
                debtLedger.quotedDebt(vaultId)
            );
        } else {
            _validateHealth(
                vault.collateralToken,
                vault.collateralAmount,
                debtLedger.quotedDebt(vaultId),
                config.minCollateralRatioBps
            );
        }

        if (adjustment.debtRepayment != 0) {
            debtLedger.synchronize(vaultId);
            _validateDebtFloor(vault.collateralToken, debtLedger.accountedDebt(vaultId));
            emit DebtRepaid(vaultId, msg.sender, adjustment.debtRepayment, true);
        }

        vault.lastTouchedAt = uint40(block.timestamp);
        int256 collateralDelta =
            int256(adjustment.collateralDeposit) - int256(adjustment.collateralWithdrawal);
        int256 debtDelta = int256(adjustment.debtIncrease + fee) - int256(adjustment.debtRepayment);
        emit VaultAdjusted(
            vaultId,
            collateralDelta,
            debtDelta,
            vault.collateralAmount,
            debtLedger.accountedDebt(vaultId)
        );
    }

    /// @notice Synchronizes a vault's staged debt changes.
    function synchronizeDebt(uint256 vaultId)
        external
        returns (uint256 sharesRemoved, uint256 repayment)
    {
        _activeVault(vaultId);
        return debtLedger.synchronize(vaultId);
    }

    /// @notice Closes a debt-free vault and returns all collateral.
    function closeVault(uint256 vaultId, address recipient) external nonReentrant whenNotPaused {
        if (recipient == address(0)) revert AddressZero();
        VaultData storage vault = _controlledActiveVault(vaultId);
        debtLedger.synchronize(vaultId);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        if (debt != 0) revert OutstandingDebt(debt);

        uint256 collateral = vault.collateralAmount;
        address token = vault.collateralToken;
        address owner = vault.owner;
        vault.collateralAmount = 0;
        vault.status = VaultStatus.Closed;
        vault.lastTouchedAt = uint40(block.timestamp);
        totalCollateral[token] -= collateral;
        vaultDelegate[vaultId] = address(0);

        if (collateral != 0) IERC20(token).safeTransfer(recipient, collateral);
        emit VaultClosed(vaultId, owner);
    }

    /// @notice Returns a vault's issuance health at the current oracle price.
    function riskSnapshot(uint256 vaultId) public view returns (RiskSnapshot memory snapshot) {
        VaultData storage vault = _vaults[vaultId];
        if (vault.status == VaultStatus.None) revert VaultNotFound(vaultId);

        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        snapshot.collateralValue =
            collateralRegistry.collateralValue(vault.collateralToken, vault.collateralAmount);
        snapshot.debtValue = debtLedger.quotedDebt(vaultId);
        snapshot.ratioBps = _ratio(snapshot.collateralValue, snapshot.debtValue);
        snapshot.liquidatable =
            snapshot.debtValue != 0 && snapshot.ratioBps < config.liquidationRatioBps;
    }

    /// @notice Returns debt attributed directly to the vault after staged repayments.
    function accountedDebt(uint256 vaultId) external view returns (uint256) {
        return debtLedger.accountedDebt(vaultId);
    }

    /// @notice Performs a liquidation authorized by the liquidation module.
    function executeLiquidation(
        uint256 vaultId,
        uint256 debtToRepay,
        uint256 collateralToSeize,
        address payer,
        address recipient
    ) external onlyRole(LIQUIDATION_ROLE) nonReentrant returns (uint256 actualCollateral) {
        if (payer == address(0) || recipient == address(0)) revert AddressZero();
        VaultData storage vault = _activeVault(vaultId);
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);

        uint256 collateralValue =
            collateralRegistry.collateralValue(vault.collateralToken, vault.collateralAmount);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        uint256 ratio = _ratio(collateralValue, debt);
        if (ratio >= config.liquidationRatioBps) {
            revert HealthyVault(ratio, config.liquidationRatioBps);
        }
        if (debtToRepay == 0 || debtToRepay > debt) revert OutstandingDebt(debt);

        uint256 debtWithBonus =
            FullMath.mulDivUp(debtToRepay, BPS + uint256(config.liquidationBonusBps), BPS);
        uint256 maximumCollateral =
            collateralRegistry.tokenAmountForValue(vault.collateralToken, debtWithBonus, true);
        if (collateralToSeize > maximumCollateral) collateralToSeize = maximumCollateral;

        actualCollateral =
            collateralToSeize > vault.collateralAmount ? vault.collateralAmount : collateralToSeize;
        if (actualCollateral == 0) revert AmountZero();

        stablecoin.burnFrom(payer, debtToRepay);
        debtLedger.repayAndSynchronize(vaultId, debtToRepay);
        _reduceIssuedDebt(vault.collateralToken, debtToRepay);
        vault.collateralAmount -= actualCollateral;
        totalCollateral[vault.collateralToken] -= actualCollateral;
        vault.lastTouchedAt = uint40(block.timestamp);

        IERC20(vault.collateralToken).safeTransfer(recipient, actualCollateral);
        emit LiquidationExecuted(vaultId, payer, recipient, debtToRepay, actualCollateral);
    }

    /// @notice Settles a queued stablecoin redemption against an active vault.
    function executeRedemption(
        uint256 vaultId,
        uint256 stableAmount,
        uint256 minimumCollateral,
        address stablePayer,
        address recipient,
        uint256 activityBps
    ) external onlyRole(REDEMPTION_ROLE) nonReentrant returns (uint256 collateralOut) {
        if (stablePayer == address(0) || recipient == address(0)) revert AddressZero();
        VaultData storage vault = _activeVault(vaultId);
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        if (stableAmount == 0 || stableAmount > debt) revert OutstandingDebt(debt);
        uint256 remainingDebt = debt - stableAmount;
        if (remainingDebt != 0 && remainingDebt < config.minDebt) {
            revert DebtBelowMinimum(remainingDebt, config.minDebt);
        }

        uint256 grossCollateral =
            collateralRegistry.tokenAmountForValue(vault.collateralToken, stableAmount, true);
        if (grossCollateral > vault.collateralAmount) {
            revert InsufficientCollateral(vault.collateralAmount, grossCollateral);
        }

        uint256 valueFee = feeController.redemptionFee(stableAmount, activityBps)
            + FullMath.mulDivUp(stableAmount, config.redemptionFeeBps, BPS);
        uint256 collateralFee = valueFee == 0
            ? 0
            : collateralRegistry.tokenAmountForValue(vault.collateralToken, valueFee, false);
        if (collateralFee > grossCollateral) collateralFee = grossCollateral;
        collateralOut = grossCollateral - collateralFee;
        if (collateralOut < minimumCollateral) {
            revert SlippageExceeded(collateralOut, minimumCollateral);
        }

        stablecoin.burnFrom(stablePayer, stableAmount);
        debtLedger.repayAndSynchronize(vaultId, stableAmount);
        _reduceIssuedDebt(vault.collateralToken, stableAmount);
        vault.collateralAmount -= grossCollateral;
        totalCollateral[vault.collateralToken] -= grossCollateral;
        protocolCollateralFees[vault.collateralToken] += collateralFee;
        vault.lastTouchedAt = uint40(block.timestamp);

        IERC20 token = IERC20(vault.collateralToken);
        token.safeTransfer(recipient, collateralOut);
        if (collateralFee != 0) token.safeTransfer(treasury, collateralFee);

        emit RedemptionExecuted(vaultId, recipient, stableAmount, collateralOut, collateralFee);
    }

    /// @notice Routes collateral remaining after a terminal settlement to its owner.
    function routeSurplus(uint256 vaultId, uint256 amount)
        external
        onlyRole(LIQUIDATION_ROLE)
        nonReentrant
    {
        if (surplusPool == address(0)) revert AddressZero();
        VaultData storage vault = _activeVault(vaultId);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        if (debt != 0) revert OutstandingDebt(debt);
        if (amount == 0 || amount > vault.collateralAmount) {
            revert InsufficientCollateral(vault.collateralAmount, amount);
        }

        vault.collateralAmount -= amount;
        totalCollateral[vault.collateralToken] -= amount;
        IERC20(vault.collateralToken).safeTransfer(surplusPool, amount);
        ISurplusPool(surplusPool).accountSurplus(vault.owner, vault.collateralToken, amount);
    }

    /// @notice Moves an exhausted vault's remaining obligation into protocol bad debt.
    function recognizeBadDebt(uint256 vaultId)
        external
        onlyRole(LIQUIDATION_ROLE)
        nonReentrant
        returns (uint256 amount)
    {
        VaultData storage vault = _activeVault(vaultId);
        if (vault.collateralAmount != 0) {
            revert InsufficientCollateral(0, vault.collateralAmount);
        }

        amount = debtLedger.recognizeBadDebt(vaultId);
        vault.status = VaultStatus.Liquidating;
        vault.lastTouchedAt = uint40(block.timestamp);
        emit BadDebtRecognized(vaultId, amount);
    }

    /// @notice Burns stablecoin to recapitalize a previously exhausted vault.
    function settleBadDebt(uint256 vaultId, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        stablecoin.burnFrom(msg.sender, amount);
        debtLedger.coverBadDebt(vaultId, amount);
        _reduceIssuedDebt(_vaults[vaultId].collateralToken, amount);

        if (debtLedger.badDebtOf(vaultId) == 0) {
            _vaults[vaultId].status = VaultStatus.Closed;
            _vaults[vaultId].lastTouchedAt = uint40(block.timestamp);
        }
        emit BadDebtSettled(vaultId, msg.sender, amount);
    }

    function setPaused(bool paused_) external onlyRole(GUARDIAN_ROLE) {
        paused = paused_;
        emit PauseUpdated(paused_);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert AddressZero();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function setFeeController(IFeeController newController) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newController) == address(0)) revert AddressZero();
        address previous = address(feeController);
        feeController = newController;
        emit FeeControllerUpdated(previous, address(newController));
    }

    function setSurplusPool(address newPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPool == address(0)) revert AddressZero();
        address previous = surplusPool;
        surplusPool = newPool;
        emit SurplusPoolUpdated(previous, newPool);
    }

    function _deposit(
        uint256 vaultId,
        VaultData storage vault,
        address payer,
        uint256 amount,
        CollateralConfig memory config
    ) internal {
        uint256 projected = totalCollateral[vault.collateralToken] + amount;
        if (config.depositCap != 0 && projected > config.depositCap) {
            revert DepositCapExceeded(vault.collateralToken, projected, config.depositCap);
        }

        IERC20 token = IERC20(vault.collateralToken);
        uint256 balanceBefore = token.safeBalanceOf(address(this));
        token.safeTransferFrom(payer, address(this), amount);
        uint256 received = token.safeBalanceOf(address(this)) - balanceBefore;
        if (received != amount) revert TransferAmountMismatch(amount, received);
        vault.collateralAmount += amount;
        vault.lastTouchedAt = uint40(block.timestamp);
        totalCollateral[vault.collateralToken] = projected;
        emit CollateralDeposited(vaultId, payer, amount, vault.collateralAmount);
    }

    function _withdraw(
        uint256 vaultId,
        VaultData storage vault,
        uint256 amount,
        address recipient,
        uint256 debt
    ) internal {
        if (amount > vault.collateralAmount) {
            revert InsufficientCollateral(vault.collateralAmount, amount);
        }

        uint256 remaining = vault.collateralAmount - amount;
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        _validateHealth(vault.collateralToken, remaining, debt, config.minCollateralRatioBps);

        vault.collateralAmount = remaining;
        vault.lastTouchedAt = uint40(block.timestamp);
        totalCollateral[vault.collateralToken] -= amount;
        IERC20(vault.collateralToken).safeTransfer(recipient, amount);
        emit CollateralWithdrawn(vaultId, recipient, amount, remaining);
    }

    function _mint(uint256 vaultId, VaultData storage vault, uint256 amount, address recipient)
        internal
        returns (uint256 fee)
    {
        CollateralConfig memory config = collateralRegistry.getConfig(vault.collateralToken);
        if (!config.enabled) revert UnsupportedCollateral(vault.collateralToken);
        uint256 currentIssuedDebt = issuedDebt[vault.collateralToken];
        uint256 principalProjectedDebt = currentIssuedDebt + amount;
        if (config.debtCeiling != 0 && principalProjectedDebt > config.debtCeiling) {
            revert DebtCeilingExceeded(
                vault.collateralToken, principalProjectedDebt, config.debtCeiling
            );
        }
        uint256 utilizationBps = config.debtCeiling == 0
            ? 0
            : FullMath.mulDiv(principalProjectedDebt, BPS, config.debtCeiling);
        fee = feeController.mintFee(amount, utilizationBps);
        uint256 debtIncrease = amount + fee;
        uint256 projectedDebt = currentIssuedDebt + debtIncrease;
        if (config.debtCeiling != 0 && projectedDebt > config.debtCeiling) {
            revert DebtCeilingExceeded(vault.collateralToken, projectedDebt, config.debtCeiling);
        }

        debtLedger.increaseDebt(vaultId, debtIncrease);
        uint256 debt = debtLedger.accountedDebt(vaultId);
        _validateHealth(
            vault.collateralToken, vault.collateralAmount, debt, config.minCollateralRatioBps
        );
        _validateDebtFloor(vault.collateralToken, debt);
        issuedDebt[vault.collateralToken] = projectedDebt;

        stablecoin.mint(recipient, amount);
        if (fee != 0) stablecoin.mint(treasury, fee);
        emit StablecoinMinted(vaultId, recipient, amount, fee, debt);
    }

    function _validateHealth(
        address token,
        uint256 collateralAmount,
        uint256 debt,
        uint256 requiredRatioBps
    ) internal view {
        if (debt == 0) return;
        uint256 collateralValue = collateralRegistry.collateralValue(token, collateralAmount);
        uint256 ratio = _ratio(collateralValue, debt);
        if (ratio < requiredRatioBps) {
            revert CollateralRatioTooLow(ratio, requiredRatioBps);
        }
    }

    function _validateDebtFloor(address token, uint256 debt) internal view {
        if (debt == 0) return;
        uint256 minimum = collateralRegistry.getConfig(token).minDebt;
        if (debt < minimum) revert DebtBelowMinimum(debt, minimum);
    }

    function _reduceIssuedDebt(address token, uint256 amount) internal {
        uint256 issued = issuedDebt[token];
        if (amount > issued) revert IssuedDebtInconsistent(token, issued, amount);
        issuedDebt[token] = issued - amount;
    }

    function _ratio(uint256 collateralValue, uint256 debt) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return FullMath.mulDiv(collateralValue, BPS, debt);
    }

    function _activeVault(uint256 vaultId) internal view returns (VaultData storage vault) {
        vault = _vaults[vaultId];
        if (vault.status == VaultStatus.None) revert VaultNotFound(vaultId);
        if (vault.status != VaultStatus.Active) revert VaultNotActive(vaultId);
    }

    function _controlledActiveVault(uint256 vaultId)
        internal
        view
        returns (VaultData storage vault)
    {
        vault = _activeVault(vaultId);
        if (vault.owner != msg.sender && vaultDelegate[vaultId] != msg.sender) {
            revert NotVaultController(vaultId, msg.sender);
        }
    }
}
