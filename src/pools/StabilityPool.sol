// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { VaultManager } from "../core/VaultManager.sol";
import { IERC20, IStabilityPool } from "../interfaces/IVelora.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";

/// @title StabilityPool
/// @notice Pro-rata stablecoin reserve that receives collateral from liquidations.
contract StabilityPool is ProtocolAccess, IStabilityPool {
    using SafeTransferLib for IERC20;

    struct DepositPosition {
        uint256 shares;
        uint64 epoch;
    }

    bytes32 public constant OFFSET_ROLE = keccak256("OFFSET_ROLE");
    uint256 public constant RAY = 1e27;
    uint256 public constant MAX_REWARD_TOKENS = 32;

    IERC20 public immutable stablecoin;
    address public immutable vaultManager;

    uint256 public override totalDeposits;
    uint256 public totalShares;
    uint64 public currentEpoch;
    bool public paused;

    mapping(address account => DepositPosition position) public positions;
    mapping(uint64 epoch => mapping(address token => uint256 index)) public collateralGainPerShare;
    mapping(address account => mapping(address token => uint256 index)) public gainSnapshot;
    mapping(address account => mapping(address token => uint256 amount)) public claimableCollateral;
    mapping(address token => uint256 amount) public totalAccountedCollateral;
    mapping(uint64 epoch => uint256 shares) public finalEpochShares;

    address[] private _rewardTokens;
    mapping(address token => bool known) private _knownRewardToken;
    uint256 private _entered = 1;

    error StabilityZeroAddress();
    error StabilityNotContract(address account);
    error StabilityPaused();
    error StabilityReentrantCall();
    error StabilityAmountZero();
    error StabilityInsufficientDeposit(uint256 available, uint256 requested);
    error StabilityInsufficientPool(uint256 available, uint256 requested);
    error StabilityNoShares();
    error StabilityCollateralNotReceived(address token, uint256 expected, uint256 balance);
    error StabilityRewardTokenLimit(uint256 limit);

    event StabilityDeposited(address indexed account, uint256 assets, uint256 shares);
    event StabilityWithdrawn(
        address indexed account, address indexed receiver, uint256 assets, uint256 shares
    );
    event StabilityOffset(
        uint64 indexed epoch,
        address indexed collateralToken,
        uint256 debtOffset,
        uint256 collateralAdded,
        uint256 depositsRemaining
    );
    event StabilityEpochAdvanced(uint64 indexed previousEpoch, uint64 indexed newEpoch);
    event StabilityGainClaimed(
        address indexed account, address indexed token, address indexed receiver, uint256 amount
    );
    event StabilityPauseUpdated(bool paused);

    modifier nonReentrant() {
        if (_entered != 1) revert StabilityReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert StabilityPaused();
        _;
    }

    constructor(address initialAdmin, VaultManager vaultManager_) ProtocolAccess(initialAdmin) {
        if (address(vaultManager_) == address(0)) revert StabilityZeroAddress();
        if (address(vaultManager_).code.length == 0) {
            revert StabilityNotContract(address(vaultManager_));
        }
        vaultManager = address(vaultManager_);
        stablecoin = IERC20(address(vaultManager_.stablecoin()));
        stablecoin.forceApprove(address(vaultManager_), type(uint256).max);
    }

    function rewardTokens() external view returns (address[] memory) {
        return _rewardTokens;
    }

    function depositOf(address account) public view returns (uint256) {
        DepositPosition storage position = positions[account];
        if (position.epoch != currentEpoch || totalShares == 0) return 0;
        return FullMath.mulDiv(position.shares, totalDeposits, totalShares);
    }

    function pendingCollateralGain(address account, address token) public view returns (uint256) {
        DepositPosition storage position = positions[account];
        uint256 pending = claimableCollateral[account][token];
        if (position.shares == 0) return pending;
        uint256 index = collateralGainPerShare[position.epoch][token];
        uint256 snapshot = gainSnapshot[account][token];
        if (index > snapshot) pending += FullMath.mulDiv(position.shares, index - snapshot, RAY);
        return pending;
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused returns (uint256 shares) {
        if (amount == 0) revert StabilityAmountZero();
        _checkpoint(msg.sender);

        if (positions[msg.sender].shares == 0) {
            uint256 rewardTokenCount = _rewardTokens.length;
            for (uint256 i; i < rewardTokenCount; ++i) {
                address token = _rewardTokens[i];
                gainSnapshot[msg.sender][token] = collateralGainPerShare[currentEpoch][token];
            }
        }

        shares = totalShares == 0 || totalDeposits == 0
            ? amount
            : FullMath.mulDiv(amount, totalShares, totalDeposits);
        if (shares == 0) revert StabilityNoShares();

        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        positions[msg.sender].shares += shares;
        totalShares += shares;
        totalDeposits += amount;
        emit StabilityDeposited(msg.sender, amount, shares);
    }

    function withdraw(uint256 amount, address receiver)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (receiver == address(0)) revert StabilityZeroAddress();
        _checkpoint(msg.sender);
        uint256 available = depositOf(msg.sender);
        assets = amount == type(uint256).max ? available : amount;
        if (assets == 0) revert StabilityAmountZero();
        if (assets > available) revert StabilityInsufficientDeposit(available, assets);

        DepositPosition storage position = positions[msg.sender];
        uint256 shares = assets == available
            ? position.shares
            : FullMath.mulDivUp(assets, totalShares, totalDeposits);
        if (shares > position.shares) shares = position.shares;
        position.shares -= shares;
        totalShares -= shares;
        totalDeposits -= assets;
        stablecoin.safeTransfer(receiver, assets);
        emit StabilityWithdrawn(msg.sender, receiver, assets, shares);
    }

    /// @notice Accounts a manager-settled liquidation against pool deposits.
    /// @dev Collateral must have reached the pool before this call.
    function offset(address collateralToken, uint256 debtToOffset, uint256 collateralToAdd)
        external
        override
        onlyRole(OFFSET_ROLE)
        nonReentrant
        returns (uint256 debtOffset)
    {
        if (debtToOffset == 0 || collateralToAdd == 0) revert StabilityAmountZero();
        if (debtToOffset > totalDeposits) {
            revert StabilityInsufficientPool(totalDeposits, debtToOffset);
        }
        if (totalShares == 0) revert StabilityNoShares();

        uint256 expected = totalAccountedCollateral[collateralToken] + collateralToAdd;
        uint256 collateralBalance = IERC20(collateralToken).safeBalanceOf(address(this));
        if (collateralBalance < expected) {
            revert StabilityCollateralNotReceived(collateralToken, expected, collateralBalance);
        }
        if (!_knownRewardToken[collateralToken]) {
            if (_rewardTokens.length == MAX_REWARD_TOKENS) {
                revert StabilityRewardTokenLimit(MAX_REWARD_TOKENS);
            }
            _knownRewardToken[collateralToken] = true;
            _rewardTokens.push(collateralToken);
        }

        uint64 epoch = currentEpoch;
        collateralGainPerShare[
            epoch
        ][collateralToken] += FullMath.mulDiv(collateralToAdd, RAY, totalShares);
        totalAccountedCollateral[collateralToken] = expected;
        totalDeposits -= debtToOffset;
        debtOffset = debtToOffset;

        emit StabilityOffset(epoch, collateralToken, debtToOffset, collateralToAdd, totalDeposits);
        if (totalDeposits == 0) {
            finalEpochShares[epoch] = totalShares;
            totalShares = 0;
            currentEpoch = epoch + 1;
            emit StabilityEpochAdvanced(epoch, currentEpoch);
        }
    }

    function claimCollateral(address token, address receiver)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (receiver == address(0)) revert StabilityZeroAddress();
        _checkpoint(msg.sender);
        amount = claimableCollateral[msg.sender][token];
        if (amount == 0) revert StabilityAmountZero();
        claimableCollateral[msg.sender][token] = 0;
        totalAccountedCollateral[token] -= amount;
        IERC20(token).safeTransfer(receiver, amount);
        emit StabilityGainClaimed(msg.sender, token, receiver, amount);
    }

    function setPaused(bool paused_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = paused_;
        emit StabilityPauseUpdated(paused_);
    }

    function _checkpoint(address account) internal {
        DepositPosition storage position = positions[account];
        uint64 positionEpoch = position.epoch;
        uint256 shares = position.shares;
        uint256 length = _rewardTokens.length;

        for (uint256 i; i < length; ++i) {
            address token = _rewardTokens[i];
            uint256 index = collateralGainPerShare[positionEpoch][token];
            uint256 snapshot = gainSnapshot[account][token];
            if (shares != 0 && index > snapshot) {
                claimableCollateral[
                    account
                ][token] += FullMath.mulDiv(shares, index - snapshot, RAY);
            }
            gainSnapshot[account][token] = index;
        }

        if (positionEpoch != currentEpoch) {
            position.shares = 0;
            position.epoch = currentEpoch;
            for (uint256 i; i < length; ++i) {
                address token = _rewardTokens[i];
                gainSnapshot[account][token] = collateralGainPerShare[currentEpoch][token];
            }
        }
    }
}
