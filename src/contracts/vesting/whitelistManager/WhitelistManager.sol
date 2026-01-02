// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract WhitelistManager is OwnableUpgradeable {
    /// @notice Mapping to track whitelisted addresses (user address => project ID => isWhitelisted)
    mapping(address => mapping(uint256 => bool)) public isWhitelisted;

    /// @notice Mapping to track projects' whitelisting status (project ID => isWhitelistEnabled)
    mapping(uint256 => bool) public isWhitelistEnabled;

    /// @notice Emitted when whitelisting is enabled for a project
    /// @param projectId Id of the project
    event whitelistEnabled(uint256 projectId);

    /// @notice Emitted when whitelisting is disabled for a project
    /// @param projectId Id of the project
    event whitelistDisabled(uint256 projectId);

    /// @notice Emitted when a user is whitelisted for a project
    /// @param projectId Id of the project
    /// @param user address to whitelist
    event userWhitelisted(uint256 projectId, address user);

    /// @notice Emitted when a user is blacklisted for a project
    /// @param projectId Id of the project
    /// @param user address to whitelist
    event userBlacklisted(uint256 projectId, address user);

    function __WhitelistManager_init() internal onlyInitializing {}

    /// @notice Enables the whitelisting mechanism for a list of projects
    /// @param projectIds IDs of the projects
    function enableWhitelists(uint256[] calldata projectIds) external onlyOwner {
        uint256 len = projectIds.length;
        for (uint256 i = 0; i < len;) {
            _enableWhitelist(projectIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Enables the whitelisting mechanism for a project
    /// @param projectId ID of the project
    function enableWhitelist(uint256 projectId) external onlyOwner {
        _enableWhitelist(projectId);
    }

    /// @notice Enables the whitelisting mechanism for a project (internal logic)
    /// @param projectId ID of the project
    function _enableWhitelist(uint256 projectId) internal {
        require(!isWhitelistEnabled[projectId], "Whitelisting is already enabled for this project");
        isWhitelistEnabled[projectId] = true;
        emit whitelistEnabled(projectId);
    }

    /// @notice Disables the whitelisting mechanism for a list of projects
    /// @param projectIds IDs of the projects
    function disableWhitelists(uint256[] calldata projectIds) external onlyOwner {
        uint256 len = projectIds.length;
        for (uint256 i = 0; i < len;) {
            _disableWhitelist(projectIds[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Disables the whitelisting mechanism for a project
    /// @param projectId ID of the project
    function disableWhitelist(uint256 projectId) external onlyOwner {
        _disableWhitelist(projectId);
    }

    /// @notice Disables the whitelisting mechanism for a project (internal logic)
    /// @param projectId ID of the project
    function _disableWhitelist(uint256 projectId) internal {
        require(isWhitelistEnabled[projectId], "Whitelisting is already disabled for this project");
        isWhitelistEnabled[projectId] = false;
        emit whitelistDisabled(projectId);
    }

    /// @notice Adds users to the whitelist
    /// @param users list of the addresses of the users to add to the whitelist
    /// @param projectId ID of the project
    function addUsersToWhitelist(address[] calldata users, uint256 projectId) external onlyOwner {
        uint256 length = users.length;
        for (uint256 i = 0; i < length;) {
            _addUserToWhitelist(users[i], projectId);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Adds a user to the whitelist
    /// @param user address of the user to add to the whitelist
    /// @param projectId ID of the project
    function addUserToWhitelist(address user, uint256 projectId) external onlyOwner {
        _addUserToWhitelist(user, projectId);
    }

    /// @notice Adds a user to the whitelist (internal logic)
    /// @param user address of the user to add to the whitelist
    /// @param projectId ID of the project
    function _addUserToWhitelist(address user, uint256 projectId) internal {
        require(user != address(0), "Invalid address");
        require(!isWhitelisted[user][projectId], "Already whitelisted");
        isWhitelisted[user][projectId] = true;
        emit userWhitelisted(projectId, user);
    }

    /// @notice Removes users from the whitelist
    /// @param users list of the addresses of the users to remove from the whitelist
    /// @param projectId ID of the project
    function removeUsersFromWhitelist(address[] calldata users, uint256 projectId) external onlyOwner {
        uint256 length = users.length;
        for (uint256 i = 0; i < length;) {
            _removeUserFromWhitelist(users[i], projectId);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Removes a user from the whitelist
    /// @param user address of the user to remove from the whitelist
    /// @param projectId ID of the project
    function removeUserFromWhitelist(address user, uint256 projectId) external onlyOwner {
        _removeUserFromWhitelist(user, projectId);
    }

    /// @notice Removes a user from the whitelist (internal logic)
    /// @param user address of the user to remove from the whitelist
    /// @param projectId ID of the project
    function _removeUserFromWhitelist(address user, uint256 projectId) internal {
        require(user != address(0), "Invalid address");
        require(isWhitelisted[user][projectId], "address is not whitelisted");
        isWhitelisted[user][projectId] = false;
        emit userBlacklisted(projectId, user);
    }

    uint256[50] private __gap;
}
