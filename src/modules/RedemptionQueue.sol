// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { CollateralRegistry } from "../core/CollateralRegistry.sol";
import { VaultManager } from "../core/VaultManager.sol";
import { IERC20 } from "../interfaces/IVelora.sol";
import { FullMath } from "../libraries/FullMath.sol";
import { SafeTransferLib } from "../libraries/SafeTransferLib.sol";
import {
    RedemptionRequest,
    RedemptionStatus,
    VaultData,
    VaultStatus
} from "../types/VeloraTypes.sol";

/// @title RedemptionQueue
/// @notice Time-delayed stablecoin redemptions against selected collateral vaults.
contract RedemptionQueue is ProtocolAccess {
    using SafeTransferLib for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ACTIVITY_BPS = 5000;
    uint256 public constant MAX_ACTIVITY_INCREMENT_BPS = 2000;
    uint256 public constant ACTIVITY_DECAY_BPS_PER_HOUR = 50;

    VaultManager public immutable vaultManager;
    CollateralRegistry public immutable collateralRegistry;
    IERC20 public immutable stablecoin;

    uint48 public executionDelay = 30 minutes;
    uint48 public maximumLifetime = 7 days;
    uint256 public nextRequestId = 1;
    uint256 public lockedStablecoin;
    uint256 public redemptionActivityBps;
    uint48 public lastActivityUpdate;
    bool public paused;

    mapping(uint256 requestId => RedemptionRequest request) private _requests;
    mapping(address requester => uint256[] requestIds) private _requestIds;

    uint256 private _entered = 1;

    error RedemptionZeroAddress();
    error RedemptionNotContract(address account);
    error RedemptionPaused();
    error RedemptionReentrantCall();
    error RedemptionAmountZero();
    error RedemptionInvalidVault(uint256 vaultId);
    error RedemptionInsufficientDebt(uint256 debt, uint256 requested);
    error RedemptionInvalidWindow(uint48 deadline);
    error RedemptionNotPending(uint256 requestId);
    error RedemptionNotRequester(uint256 requestId, address caller);
    error RedemptionDelayActive(uint48 executableAt);
    error RedemptionExpired(uint48 deadline);
    error RedemptionNotExpired(uint48 deadline);
    error RedemptionInvalidTiming(uint48 delay, uint48 lifetime);

    event RedemptionQueued(
        uint256 indexed requestId,
        uint256 indexed vaultId,
        address indexed requester,
        uint256 stableAmount,
        uint48 executableAt,
        uint48 deadline
    );
    event RedemptionCancelled(uint256 indexed requestId, address indexed requester);
    event RedemptionExpiredAndRefunded(uint256 indexed requestId, address indexed requester);
    event RedemptionExecuted(
        uint256 indexed requestId,
        uint256 indexed vaultId,
        address indexed receiver,
        uint256 stableAmount,
        uint256 collateralOut,
        uint256 activityBps
    );
    event RedemptionTimingUpdated(uint48 executionDelay, uint48 maximumLifetime);
    event RedemptionPauseUpdated(bool paused);

    modifier nonReentrant() {
        if (_entered != 1) revert RedemptionReentrantCall();
        _entered = 2;
        _;
        _entered = 1;
    }

    modifier whenNotPaused() {
        if (paused) revert RedemptionPaused();
        _;
    }

    constructor(
        address initialAdmin,
        VaultManager vaultManager_,
        CollateralRegistry collateralRegistry_
    ) ProtocolAccess(initialAdmin) {
        if (address(vaultManager_) == address(0) || address(collateralRegistry_) == address(0)) {
            revert RedemptionZeroAddress();
        }
        if (address(vaultManager_).code.length == 0) {
            revert RedemptionNotContract(address(vaultManager_));
        }
        if (address(collateralRegistry_).code.length == 0) {
            revert RedemptionNotContract(address(collateralRegistry_));
        }

        vaultManager = vaultManager_;
        collateralRegistry = collateralRegistry_;
        stablecoin = IERC20(address(vaultManager_.stablecoin()));
        stablecoin.forceApprove(address(vaultManager_), type(uint256).max);
        lastActivityUpdate = uint48(block.timestamp);
    }

    function getRequest(uint256 requestId)
        external
        view
        returns (RedemptionRequest memory request)
    {
        return _requests[requestId];
    }

    function requestsOf(address requester) external view returns (uint256[] memory) {
        return _requestIds[requester];
    }

    function currentActivityBps() public view returns (uint256) {
        uint256 elapsed = block.timestamp - uint256(lastActivityUpdate);
        uint256 decay = FullMath.mulDiv(elapsed, ACTIVITY_DECAY_BPS_PER_HOUR, 1 hours);
        return redemptionActivityBps > decay ? redemptionActivityBps - decay : 0;
    }

    /// @notice Locks stablecoin and creates a redemption executable after the protocol delay.
    function requestRedemption(
        uint256 vaultId,
        uint256 stableAmount,
        uint256 minCollateralOut,
        address receiver,
        uint48 deadline
    ) external nonReentrant whenNotPaused returns (uint256 requestId) {
        if (stableAmount == 0) revert RedemptionAmountZero();
        if (receiver == address(0)) revert RedemptionZeroAddress();

        uint48 nowTime = uint48(block.timestamp);
        if (deadline < nowTime + executionDelay || deadline > nowTime + maximumLifetime) {
            revert RedemptionInvalidWindow(deadline);
        }

        VaultData memory vault = vaultManager.getVault(vaultId);
        if (vault.status != VaultStatus.Active) revert RedemptionInvalidVault(vaultId);
        uint256 debt = vaultManager.accountedDebt(vaultId);
        if (stableAmount > debt) revert RedemptionInsufficientDebt(debt, stableAmount);

        stablecoin.safeTransferFrom(msg.sender, address(this), stableAmount);
        lockedStablecoin += stableAmount;

        requestId = nextRequestId++;
        RedemptionRequest storage request = _requests[requestId];
        request.id = requestId;
        request.vaultId = vaultId;
        request.requester = msg.sender;
        request.receiver = receiver;
        request.collateralToken = vault.collateralToken;
        request.stableAmount = stableAmount;
        request.minCollateralOut = minCollateralOut;
        request.status = RedemptionStatus.Pending;
        request.createdAt = nowTime;
        request.executableAt = nowTime + executionDelay;
        request.deadline = deadline;
        _requestIds[msg.sender].push(requestId);

        emit RedemptionQueued(
            requestId, vaultId, msg.sender, stableAmount, request.executableAt, deadline
        );
    }

    function cancelRedemption(uint256 requestId) external nonReentrant {
        RedemptionRequest storage request = _pendingRequest(requestId);
        if (request.requester != msg.sender) {
            revert RedemptionNotRequester(requestId, msg.sender);
        }
        request.status = RedemptionStatus.Cancelled;
        lockedStablecoin -= request.stableAmount;
        stablecoin.safeTransfer(request.requester, request.stableAmount);
        emit RedemptionCancelled(requestId, request.requester);
    }

    function expireRedemption(uint256 requestId) external nonReentrant {
        RedemptionRequest storage request = _pendingRequest(requestId);
        if (block.timestamp <= request.deadline) revert RedemptionNotExpired(request.deadline);
        request.status = RedemptionStatus.Expired;
        lockedStablecoin -= request.stableAmount;
        stablecoin.safeTransfer(request.requester, request.stableAmount);
        emit RedemptionExpiredAndRefunded(requestId, request.requester);
    }

    /// @notice Burns locked stablecoin and delivers collateral to the request receiver.
    function executeRedemption(uint256 requestId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 collateralOut)
    {
        RedemptionRequest storage request = _pendingRequest(requestId);
        uint48 executableAt = request.executableAt;
        if (block.timestamp < executableAt) revert RedemptionDelayActive(executableAt);
        if (block.timestamp > request.deadline) revert RedemptionExpired(request.deadline);

        uint256 debtBefore = vaultManager.accountedDebt(request.vaultId);
        if (request.stableAmount > debtBefore) {
            revert RedemptionInsufficientDebt(debtBefore, request.stableAmount);
        }
        uint256 activity = currentActivityBps();
        uint256 grossCollateral = collateralRegistry.tokenAmountForValue(
            request.collateralToken, request.stableAmount, true
        );

        request.status = RedemptionStatus.Executed;
        lockedStablecoin -= request.stableAmount;
        collateralOut = vaultManager.executeRedemption(
            request.vaultId,
            request.stableAmount,
            request.minCollateralOut,
            address(this),
            request.receiver,
            activity
        );
        request.collateralOut = collateralOut;
        request.feeAmount = grossCollateral > collateralOut ? grossCollateral - collateralOut : 0;

        uint256 volumeBps = FullMath.mulDiv(request.stableAmount, BPS, debtBefore);
        uint256 increment = FullMath.min(volumeBps, MAX_ACTIVITY_INCREMENT_BPS);
        redemptionActivityBps = FullMath.min(activity + increment, MAX_ACTIVITY_BPS);
        lastActivityUpdate = uint48(block.timestamp);

        emit RedemptionExecuted(
            requestId,
            request.vaultId,
            request.receiver,
            request.stableAmount,
            collateralOut,
            activity
        );
    }

    function setTiming(uint48 delay, uint48 lifetime) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (delay == 0 || lifetime < delay || lifetime > 30 days) {
            revert RedemptionInvalidTiming(delay, lifetime);
        }
        executionDelay = delay;
        maximumLifetime = lifetime;
        emit RedemptionTimingUpdated(delay, lifetime);
    }

    function setPaused(bool paused_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = paused_;
        emit RedemptionPauseUpdated(paused_);
    }

    function _pendingRequest(uint256 requestId)
        internal
        view
        returns (RedemptionRequest storage request)
    {
        request = _requests[requestId];
        if (request.status != RedemptionStatus.Pending) revert RedemptionNotPending(requestId);
    }
}
