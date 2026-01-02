// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITVSManager {
    // TYPEDEF
    /// @notice Represents an allocation
    /// @dev Tracks the allocation status and vesting progress
    struct Allocation {
        uint256[] amounts; // Amount of tokens committed for this allocation for all flows
        uint256[] vestingPeriods; // Chosen vesting duration in seconds for all flows
        uint256[] vestingStartTimes; // start time of the vesting for all flows
        uint256[] claimedSeconds; // Number of seconds already claimed for all flows
        bool[] claimedFlows; // Whether flow is claimed
        IERC20 token; // The TVS token
        uint256 projectId; // projectId
        bool isBiddingProject; // whether the TVS comes from a bidding or a reward project
        uint256 poolId; // id of the pool
    }

    function setTVS(
        uint256 nftId,
        uint256 _amount,
        uint256 _vestingPeriod,
        uint256 _vestingStartTime,
        IERC20 _token,
        uint256 projectId,
        bool isBiddingProject,
        uint256 _poolId
    ) external;

    function treasury() external returns (address);

    function pause() external;

    function unpause() external;

    function getAllocationOf(uint256 nftId) external returns (Allocation memory);
}
