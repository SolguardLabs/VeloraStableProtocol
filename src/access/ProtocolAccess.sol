// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ProtocolAccess
/// @notice Role-based authorization with a delayed, two-step default-admin handover.
abstract contract ProtocolAccess {
    struct RoleData {
        mapping(address account => bool enabled) members;
        bytes32 adminRole;
    }

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    uint48 public constant MAX_ADMIN_TRANSFER_DELAY = 30 days;
    uint48 public constant INITIAL_ADMIN_TRANSFER_DELAY = 2 days;

    mapping(bytes32 role => RoleData data) private _roles;

    address private _defaultAdmin;
    address private _pendingDefaultAdmin;
    uint48 private _pendingDefaultAdminSchedule;
    uint48 private _defaultAdminDelay;

    error AccessUnauthorized(address account, bytes32 requiredRole);
    error AccessZeroAddress();
    error AccessBadConfirmation();
    error AccessDefaultAdminManagedSeparately();
    error AccessNoPendingAdmin();
    error AccessAdminTransferNotReady(uint48 schedule);
    error AccessDelayTooLong(uint48 delay);
    error AccessAlreadyDefaultAdmin(address account);

    event RoleAdminChanged(
        bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole
    );
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event DefaultAdminTransferScheduled(
        address indexed currentAdmin, address indexed pendingAdmin, uint48 schedule
    );
    event DefaultAdminTransferCanceled(address indexed currentAdmin, address indexed canceledAdmin);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event DefaultAdminDelayChanged(uint48 previousDelay, uint48 newDelay);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert AccessZeroAddress();

        _defaultAdmin = initialAdmin;
        _defaultAdminDelay = INITIAL_ADMIN_TRANSFER_DELAY;
        _roles[DEFAULT_ADMIN_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role, msg.sender);
        _;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role].members[account];
    }

    function getRoleAdmin(bytes32 role) public view returns (bytes32) {
        return _roles[role].adminRole;
    }

    function defaultAdmin() public view returns (address) {
        return _defaultAdmin;
    }

    function pendingDefaultAdmin() public view returns (address account, uint48 schedule) {
        return (_pendingDefaultAdmin, _pendingDefaultAdminSchedule);
    }

    function defaultAdminDelay() public view returns (uint48) {
        return _defaultAdminDelay;
    }

    function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        if (role == DEFAULT_ADMIN_ROLE) revert AccessDefaultAdminManagedSeparately();
        if (account == address(0)) revert AccessZeroAddress();
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {
        if (role == DEFAULT_ADMIN_ROLE) revert AccessDefaultAdminManagedSeparately();
        _revokeRole(role, account);
    }

    function renounceRole(bytes32 role, address confirmation) public virtual {
        if (confirmation != msg.sender) revert AccessBadConfirmation();
        if (role == DEFAULT_ADMIN_ROLE) revert AccessDefaultAdminManagedSeparately();
        _revokeRole(role, confirmation);
    }

    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (role == DEFAULT_ADMIN_ROLE) revert AccessDefaultAdminManagedSeparately();
        _setRoleAdmin(role, adminRole);
    }

    function scheduleDefaultAdminTransfer(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert AccessZeroAddress();
        if (newAdmin == _defaultAdmin) revert AccessAlreadyDefaultAdmin(newAdmin);

        uint48 schedule = uint48(block.timestamp) + _defaultAdminDelay;
        _pendingDefaultAdmin = newAdmin;
        _pendingDefaultAdminSchedule = schedule;
        emit DefaultAdminTransferScheduled(_defaultAdmin, newAdmin, schedule);
    }

    function cancelDefaultAdminTransfer() external onlyRole(DEFAULT_ADMIN_ROLE) {
        address canceledAdmin = _pendingDefaultAdmin;
        if (canceledAdmin == address(0)) revert AccessNoPendingAdmin();

        delete _pendingDefaultAdmin;
        delete _pendingDefaultAdminSchedule;
        emit DefaultAdminTransferCanceled(_defaultAdmin, canceledAdmin);
    }

    function acceptDefaultAdminTransfer() external {
        address newAdmin = _pendingDefaultAdmin;
        uint48 schedule = _pendingDefaultAdminSchedule;
        if (newAdmin == address(0) || msg.sender != newAdmin) revert AccessNoPendingAdmin();
        if (block.timestamp < schedule) revert AccessAdminTransferNotReady(schedule);

        address previousAdmin = _defaultAdmin;
        delete _pendingDefaultAdmin;
        delete _pendingDefaultAdminSchedule;
        _defaultAdmin = newAdmin;

        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        emit DefaultAdminTransferred(previousAdmin, newAdmin);
    }

    function setDefaultAdminDelay(uint48 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay > MAX_ADMIN_TRANSFER_DELAY) revert AccessDelayTooLong(newDelay);
        uint48 previousDelay = _defaultAdminDelay;
        _defaultAdminDelay = newDelay;
        emit DefaultAdminDelayChanged(previousDelay, newDelay);
    }

    function _checkRole(bytes32 role, address account) internal view virtual {
        if (!hasRole(role, account)) revert AccessUnauthorized(account, role);
    }

    function _setRoleAdmin(bytes32 role, bytes32 adminRole) internal virtual {
        bytes32 previousAdminRole = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previousAdminRole, adminRole);
    }

    function _grantRole(bytes32 role, address account) internal virtual returns (bool) {
        if (_roles[role].members[account]) return false;
        _roles[role].members[account] = true;
        emit RoleGranted(role, account, msg.sender);
        return true;
    }

    function _revokeRole(bytes32 role, address account) internal virtual returns (bool) {
        if (!_roles[role].members[account]) return false;
        _roles[role].members[account] = false;
        emit RoleRevoked(role, account, msg.sender);
        return true;
    }
}
