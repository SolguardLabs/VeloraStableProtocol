// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { IPriceOracle } from "../interfaces/IVelora.sol";
import { PriceData } from "../types/VeloraTypes.sol";

/// @title VeloraPriceOracle
/// @notice Stores bounded, heartbeat-limited USD prices reported in 18-decimal precision.
contract VeloraPriceOracle is ProtocolAccess, IPriceOracle {
    struct Feed {
        uint192 price;
        uint192 minPrice;
        uint192 maxPrice;
        uint80 roundId;
        uint48 updatedAt;
        uint48 validUntil;
        uint48 heartbeat;
        bool configured;
        bool paused;
    }

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    uint48 public constant MIN_HEARTBEAT = 1 minutes;
    uint48 public constant MAX_HEARTBEAT = 7 days;

    mapping(bytes32 oracleId => Feed feed) private _feeds;
    bytes32[] private _feedIds;
    bool public globallyPaused;

    error OracleInvalidFeedId();
    error OracleFeedNotConfigured(bytes32 oracleId);
    error OracleFeedAlreadyConfigured(bytes32 oracleId);
    error OracleInvalidHeartbeat(uint48 heartbeat);
    error OracleInvalidBounds(uint256 minPrice, uint256 maxPrice);
    error OraclePriceOutOfBounds(
        bytes32 oracleId, uint256 price, uint256 minPrice, uint256 maxPrice
    );
    error OraclePriceOverflow(uint256 price);
    error OraclePaused(bytes32 oracleId);
    error OraclePriceUnavailable(bytes32 oracleId);
    error OracleStalePrice(bytes32 oracleId, uint48 updatedAt, uint48 validUntil);
    error OracleArrayLengthMismatch();
    error OracleIndexOutOfBounds(uint256 index);

    event FeedConfigured(
        bytes32 indexed oracleId, uint48 heartbeat, uint256 minPrice, uint256 maxPrice
    );
    event FeedBoundsUpdated(bytes32 indexed oracleId, uint256 minPrice, uint256 maxPrice);
    event FeedHeartbeatUpdated(
        bytes32 indexed oracleId, uint48 previousHeartbeat, uint48 newHeartbeat
    );
    event FeedPauseChanged(bytes32 indexed oracleId, bool paused, address indexed caller);
    event GlobalPauseChanged(bool paused, address indexed caller);
    event PriceReported(
        bytes32 indexed oracleId,
        uint80 indexed roundId,
        uint256 price,
        uint48 updatedAt,
        uint48 validUntil,
        address reporter
    );

    constructor(address initialAdmin) ProtocolAccess(initialAdmin) { }

    function configureFeed(bytes32 oracleId, uint48 heartbeat, uint256 minPrice, uint256 maxPrice)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (oracleId == bytes32(0)) revert OracleInvalidFeedId();
        if (_feeds[oracleId].configured) revert OracleFeedAlreadyConfigured(oracleId);
        _validateConfiguration(heartbeat, minPrice, maxPrice);

        Feed storage feed = _feeds[oracleId];
        feed.minPrice = uint192(minPrice);
        feed.maxPrice = uint192(maxPrice);
        feed.heartbeat = heartbeat;
        feed.configured = true;
        _feedIds.push(oracleId);

        emit FeedConfigured(oracleId, heartbeat, minPrice, maxPrice);
    }

    function setFeedBounds(bytes32 oracleId, uint256 minPrice, uint256 maxPrice)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Feed storage feed = _configuredFeed(oracleId);
        _validateBounds(minPrice, maxPrice);
        if (feed.price != 0 && (feed.price < minPrice || feed.price > maxPrice)) {
            revert OraclePriceOutOfBounds(oracleId, feed.price, minPrice, maxPrice);
        }
        feed.minPrice = uint192(minPrice);
        feed.maxPrice = uint192(maxPrice);
        emit FeedBoundsUpdated(oracleId, minPrice, maxPrice);
    }

    function setHeartbeat(bytes32 oracleId, uint48 newHeartbeat)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        Feed storage feed = _configuredFeed(oracleId);
        _validateHeartbeat(newHeartbeat);
        uint48 previousHeartbeat = feed.heartbeat;
        feed.heartbeat = newHeartbeat;
        if (feed.updatedAt != 0) feed.validUntil = feed.updatedAt + newHeartbeat;
        emit FeedHeartbeatUpdated(oracleId, previousHeartbeat, newHeartbeat);
    }

    function pauseFeed(bytes32 oracleId) external onlyRole(GUARDIAN_ROLE) {
        Feed storage feed = _configuredFeed(oracleId);
        if (!feed.paused) {
            feed.paused = true;
            emit FeedPauseChanged(oracleId, true, msg.sender);
        }
    }

    function unpauseFeed(bytes32 oracleId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Feed storage feed = _configuredFeed(oracleId);
        if (feed.paused) {
            feed.paused = false;
            emit FeedPauseChanged(oracleId, false, msg.sender);
        }
    }

    function pauseAll() external onlyRole(GUARDIAN_ROLE) {
        if (!globallyPaused) {
            globallyPaused = true;
            emit GlobalPauseChanged(true, msg.sender);
        }
    }

    function unpauseAll() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (globallyPaused) {
            globallyPaused = false;
            emit GlobalPauseChanged(false, msg.sender);
        }
    }

    function reportPrice(bytes32 oracleId, uint256 price) external onlyRole(REPORTER_ROLE) {
        _reportPrice(oracleId, price);
    }

    function reportPrices(bytes32[] calldata oracleIds, uint256[] calldata prices)
        external
        onlyRole(REPORTER_ROLE)
    {
        uint256 length = oracleIds.length;
        if (length != prices.length) revert OracleArrayLengthMismatch();
        for (uint256 i; i < length; ++i) {
            _reportPrice(oracleIds[i], prices[i]);
        }
    }

    /// @notice Returns the live USD price, scaled to 1e18 per whole collateral token.
    function getPrice(bytes32 oracleId) external view override returns (uint256) {
        Feed storage feed = _liveFeed(oracleId);
        return uint256(feed.price);
    }

    function getPriceData(bytes32 oracleId) public view override returns (PriceData memory data) {
        Feed storage feed = _liveFeed(oracleId);
        data = PriceData({
            price: uint256(feed.price),
            updatedAt: feed.updatedAt,
            validUntil: feed.validUntil,
            roundId: feed.roundId
        });
    }

    function feedState(bytes32 oracleId) external view returns (Feed memory) {
        Feed storage feed = _configuredFeed(oracleId);
        return feed;
    }

    function isPriceLive(bytes32 oracleId) external view returns (bool) {
        Feed storage feed = _feeds[oracleId];
        return feed.configured && !globallyPaused && !feed.paused && feed.price != 0
            && block.timestamp <= feed.validUntil;
    }

    function feedCount() external view returns (uint256) {
        return _feedIds.length;
    }

    function feedIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _feedIds.length) revert OracleIndexOutOfBounds(index);
        return _feedIds[index];
    }

    function _reportPrice(bytes32 oracleId, uint256 price) internal {
        Feed storage feed = _configuredFeed(oracleId);
        if (globallyPaused || feed.paused) revert OraclePaused(oracleId);
        if (price > type(uint192).max) revert OraclePriceOverflow(price);
        if (price < feed.minPrice || price > feed.maxPrice) {
            revert OraclePriceOutOfBounds(oracleId, price, feed.minPrice, feed.maxPrice);
        }

        uint48 timestamp = uint48(block.timestamp);
        uint80 roundId = feed.roundId + 1;
        uint48 validUntil = timestamp + feed.heartbeat;
        feed.price = uint192(price);
        feed.roundId = roundId;
        feed.updatedAt = timestamp;
        feed.validUntil = validUntil;

        emit PriceReported(oracleId, roundId, price, timestamp, validUntil, msg.sender);
    }

    function _liveFeed(bytes32 oracleId) internal view returns (Feed storage feed) {
        feed = _configuredFeed(oracleId);
        if (globallyPaused || feed.paused) revert OraclePaused(oracleId);
        if (feed.price == 0) revert OraclePriceUnavailable(oracleId);
        if (block.timestamp > feed.validUntil) {
            revert OracleStalePrice(oracleId, feed.updatedAt, feed.validUntil);
        }
    }

    function _configuredFeed(bytes32 oracleId) internal view returns (Feed storage feed) {
        feed = _feeds[oracleId];
        if (!feed.configured) revert OracleFeedNotConfigured(oracleId);
    }

    function _validateConfiguration(uint48 heartbeat, uint256 minPrice, uint256 maxPrice)
        internal
        pure
    {
        _validateHeartbeat(heartbeat);
        _validateBounds(minPrice, maxPrice);
    }

    function _validateHeartbeat(uint48 heartbeat) internal pure {
        if (heartbeat < MIN_HEARTBEAT || heartbeat > MAX_HEARTBEAT) {
            revert OracleInvalidHeartbeat(heartbeat);
        }
    }

    function _validateBounds(uint256 minPrice, uint256 maxPrice) internal pure {
        if (minPrice == 0 || minPrice >= maxPrice || maxPrice > type(uint192).max) {
            revert OracleInvalidBounds(minPrice, maxPrice);
        }
    }
}
