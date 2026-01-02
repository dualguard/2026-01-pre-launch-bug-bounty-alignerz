// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TVSManager} from "../contracts/vesting/TVSManager.sol";

library TVSCalculator {
    using TVSCalculator for TVSManager.Allocation;

    uint256 internal constant BASIS_POINT = 10_000;

    error Splitting_Should_Not_Zero_Down_Amounts();

    /**
     * @notice Calculates fee and updated claimedSeconds for a TVS
     * @param allocation the TVS allocation
     * @param feeRate fee rate in basis points
     */
    function calculateFeeAndNewClaimedSecondsForOneTVS(TVSManager.Allocation memory allocation, uint256 feeRate)
        internal
        pure
        returns (uint256 feeAmount, uint256[] memory newAmounts)
    {
        uint256[] memory amounts = allocation.amounts;
        uint256[] memory claimedAmounts = allocation.claimedAmounts;
        uint256 length = amounts.length;
        newAmounts = new uint256[](length);

        for (uint256 i; i < length;) {
            uint256 amount = amounts[i];
            if (allocation.claimedFlows[i]) {
                newAmounts[i] = amount;
            } else {
                uint256 claimedAmount = claimedAmounts[i];
                uint256 unclaimedAmount = amount - claimedAmount;
                uint256 fee = unclaimedAmount * feeRate / BASIS_POINT;
                newAmounts[i] = amount - fee;
                feeAmount += fee;
            }
            unchecked {
                ++i;
            }
        }
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /**
     * @notice Computes split arrays for a split operation
     * @param allocation base allocation
     * @param percentage split percentage (in basis points)
     * @param nbOfFlows number of token flows
     */
    function computeSplitArrays(TVSManager.Allocation memory allocation, uint256 percentage, uint256 nbOfFlows)
        internal
        pure
        returns (
            uint256[] memory newVestingPeriods,
            uint256[] memory newStartTimes,
            uint256[] memory newAmounts,
            uint256[] memory newClaimedAmounts,
            bool[] memory newClaimedFlows
        )
    {
        newVestingPeriods = new uint256[](nbOfFlows);
        newStartTimes = new uint256[](nbOfFlows);
        newAmounts = new uint256[](nbOfFlows);
        newClaimedAmounts = new uint256[](nbOfFlows);
        newClaimedFlows = new bool[](nbOfFlows);

        uint256[] memory baseAmounts = allocation.amounts;
        uint256[] memory baseClaimedAmounts = allocation.claimedAmounts;
        for (uint256 j; j < nbOfFlows;) {
            uint256 amount = (baseAmounts[j] * percentage) / BASIS_POINT;
            require(amount > 0, Splitting_Should_Not_Zero_Down_Amounts());
            uint256 claimedAmount;
            if (!allocation.claimedFlows[j]) {
                claimedAmount = ceilDiv((baseClaimedAmounts[j] * percentage), BASIS_POINT);
                if (claimedAmount > amount) claimedAmount = amount;
            } else {
                claimedAmount = amount;
            }
            newAmounts[j] = amount;
            newClaimedAmounts[j] = claimedAmount;
            newVestingPeriods[j] = allocation.vestingPeriods[j];
            newStartTimes[j] = allocation.vestingStartTimes[j];
            newClaimedFlows[j] = allocation.claimedFlows[j];

            unchecked {
                ++j;
            }
        }
    }
}
