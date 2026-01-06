// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {A26Z} from "./contracts/token/A26Z.sol";
import {AlignerzNFT} from "./contracts/nft/AlignerzNFT.sol";
import {Alignerz} from "./contracts/vesting/Alignerz.sol";
import {TVSManager} from "./contracts/vesting/TVSManager.sol";
import {
    ERC1967Proxy
} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IERC721Receiver
} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

// Hevm cheatcode interface for Medusa/Echidna
interface IHevm {
    function warp(uint256) external;
    function roll(uint256) external;
    function prank(address) external;
}

/**
 * @title TVSMedusaHarness - Multi-Token Fuzzing Harness
 * @notice Designed for comprehensive fuzzing with 2 tokens and conditional state tracking
 * @dev Implements IERC721Receiver to receive NFTs minted during merge operations
 * @author 0xtimefliez
 */
contract TVSMedusaHarness is IERC721Receiver {
    using SafeERC20 for IERC20;

    // Standard Medusa cheatcode address
    IHevm constant hevm = IHevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // === CORE CONTRACTS ===
    A26Z public tokenA; // Token for project 0
    A26Z public tokenB; // Token for project 1
    AlignerzNFT public nft;
    Alignerz public alignerz;
    TVSManager public tvsManager;

    address public owner;

    // === NFT TRACKING BY PROJECT ===
    // Track NFTs separately by project for easy compatible merges
    uint256[] public project0NftIds; // NFTs from project 0 (tokenA)
    uint256[] public project1NftIds; // NFTs from project 1 (tokenB)

    // Combined tracking for random operations
    uint256[] public allNftIds;

    // === GHOST VARIABLES ===
    uint256 public ghost_totalMinted;
    uint256 public ghost_totalBurned;
    uint256 public ghost_totalMerges;
    uint256 public ghost_totalSplits;
    uint256 public ghost_totalClaims;

    // Value tracking for conservation invariants
    uint256 public ghost_mergeInputValue; // Sum of input NFT values before merge
    uint256 public ghost_mergeOutputValue; // Output NFT value after merge
    uint256 public ghost_mergeFeesPaid; // Fees taken during merges
    uint256 public ghost_splitInputValue; // Original NFT value before split
    uint256 public ghost_splitOutputValue; // Sum of new NFT values after split
    uint256 public ghost_splitFeesPaid; // Fees taken during splits

    // === STATE FLAGS ===
    bool public project0Seeded;
    bool public project1Seeded;

    constructor() {
        owner = address(this);

        // Create two tokens
        tokenA = new A26Z("Token A", "TKNA");
        tokenB = new A26Z("Token B", "TKNB");
        nft = new AlignerzNFT("NFT", "NFT", "http://test/");

        // Deploy TVSManager
        address tvsImpl = address(new TVSManager());
        address tvsProxy = address(
            new ERC1967Proxy(
                tvsImpl,
                abi.encodeCall(TVSManager.initialize, (address(nft)))
            )
        );
        tvsManager = TVSManager(payable(tvsProxy));

        // Deploy Alignerz
        address alignerzImpl = address(new Alignerz());
        address alignerzProxy = address(
            new ERC1967Proxy(
                alignerzImpl,
                abi.encodeCall(
                    Alignerz.initialize,
                    (address(nft), address(tvsManager))
                )
            )
        );
        alignerz = Alignerz(payable(alignerzProxy));

        // Setup permissions
        nft.addMinter(address(tvsManager));
        nft.addMinter(address(alignerz));
        tvsManager.setTreasury(owner);
        tvsManager.setAlignerz(address(alignerz));

        // Fee setup (2%)
        try tvsManager.setSplitFeeRate(200) {} catch (bytes memory reason) {
            _checkError(reason);
        }
        try tvsManager.setMergeFeeRate(200) {} catch (bytes memory reason) {
            _checkError(reason);
        }
        // Approvals for both tokens
        tokenA.approve(address(alignerz), type(uint256).max);
        tokenB.approve(address(alignerz), type(uint256).max);

        // NOTE: DO NOT add NFT approvals - protocol requires _hasZeroApprovals for operations

        // === SEED INITIAL STATE ===
        _seedProject0();
        _seedProject1();
    }

    function _seedProject0() internal {
        // Launch Project 0 with tokenA
        uint256 seedAmount = 500_000e18;
        alignerz.launchRewardProject(address(tokenA), seedAmount, 10);

        // Allocate and mint 3 NFTs for project 0
        address[] memory kols = new address[](1);
        kols[0] = address(this);
        uint256[] memory amounts = new uint256[](1);

        for (uint256 i = 0; i < 3; i++) {
            amounts[0] = 50_000e18;
            alignerz.setTVSAllocation(0, 1000, 50_000e18, kols, amounts);
            uint256 nftId = alignerz.claimRewardTVS(0);
            project0NftIds.push(nftId);
            allNftIds.push(nftId);
            ghost_totalMinted++;
        }
        project0Seeded = true;
    }

    function _seedProject1() internal {
        // Launch Project 1 with tokenB
        uint256 seedAmount = 500_000e18;
        alignerz.launchRewardProject(address(tokenB), seedAmount, 10);

        // Allocate and mint 3 NFTs for project 1
        address[] memory kols = new address[](1);
        kols[0] = address(this);
        uint256[] memory amounts = new uint256[](1);

        for (uint256 i = 0; i < 3; i++) {
            amounts[0] = 50_000e18;
            alignerz.setTVSAllocation(1, 1000, 50_000e18, kols, amounts);
            uint256 nftId = alignerz.claimRewardTVS(1);
            project1NftIds.push(nftId);
            allNftIds.push(nftId);
            ghost_totalMinted++;
        }
        project1Seeded = true;
    }

    // === MINTING ACTIONS ===

    /// @notice Mint a new NFT from project 0 or 1 with random amount
    function mintNft(uint256 projectSeed, uint256 amountSeed) external {
        uint256 projectId = projectSeed % 2; // 0 or 1
        uint256 amount = _bound(amountSeed, 1_000e18, 100_000e18);

        address tokenAddr = projectId == 0 ? address(tokenA) : address(tokenB);

        address[] memory kols = new address[](1);
        kols[0] = address(this);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        try alignerz.setTVSAllocation(projectId, 1000, amount, kols, amounts) {
            try alignerz.claimRewardTVS(projectId) returns (uint256 nftId) {
                if (projectId == 0) {
                    project0NftIds.push(nftId);
                } else {
                    project1NftIds.push(nftId);
                }
                allNftIds.push(nftId);
                ghost_totalMinted++;
            } catch (bytes memory reason) {
                _checkError(reason);
            }
        } catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    /// @notice Top up a project with more tokens (allows more allocations)
    function topUpProject(uint256 projectSeed, uint256 amountSeed) external {
        uint256 projectId = projectSeed % 2;
        uint256 amount = _bound(amountSeed, 10_000e18, 500_000e18);

        address tokenAddr = projectId == 0 ? address(tokenA) : address(tokenB);

        try alignerz.launchRewardProject(tokenAddr, amount, 10) {} catch (
            bytes memory reason
        ) {
            _checkError(reason);
        }
    }

    // === MERGE ACTIONS (PROJECT-SPECIFIC) ===

    /// @notice Merge two NFTs from the same project (guaranteed compatibility)
    function mergeFromProject0(uint256 seed1, uint256 seed2) external {
        _mergeFromProject(project0NftIds, seed1, seed2);
    }

    function mergeFromProject1(uint256 seed1, uint256 seed2) external {
        _mergeFromProject(project1NftIds, seed1, seed2);
    }

    function _mergeFromProject(
        uint256[] storage projectNfts,
        uint256 seed1,
        uint256 seed2
    ) internal {
        if (projectNfts.length < 2) return;

        uint256 idx1 = seed1 % projectNfts.length;
        uint256 idx2 = seed2 % projectNfts.length;
        if (idx1 == idx2) {
            idx2 = (idx2 + 1) % projectNfts.length;
        }

        uint256 nftId1 = projectNfts[idx1];
        uint256 nftId2 = projectNfts[idx2];

        // Validate ownership
        if (!_isOwnedByUs(nftId1)) {
            _removeFromProject(projectNfts, idx1);
            return;
        }
        if (!_isOwnedByUs(nftId2)) {
            _removeFromProject(projectNfts, idx2);
            return;
        }

        // Validate allocations exist
        TVSManager.Allocation memory alloc1 = tvsManager.getAllocationOf(
            nftId1
        );
        if (address(alloc1.token) == address(0) || alloc1.amounts.length == 0) {
            _removeFromProject(projectNfts, idx1);
            return;
        }

        // NOTE: No NFT approval needed - TVSManager is a minter and can burn directly
        // Also, protocols require _hasZeroApprovals for merge to work

        // === VALUE CONSERVATION: Capture input values BEFORE merge ===
        // Merges operate on REMAINING value (amounts - claimed), not total amounts
        uint256 totalInputValue = _sumRemainingAmounts(alloc1) +
            _sumRemainingAmounts(tvsManager.getAllocationOf(nftId2));

        uint256[] memory mergeIds = new uint256[](2);
        mergeIds[0] = nftId1;
        mergeIds[1] = nftId2;

        try tvsManager.mergeTVS(mergeIds) returns (uint256 mergedId) {
            // === VALUE CONSERVATION: Capture output value AFTER merge ===
            uint256 outputValue = _sumAmounts(
                tvsManager.getAllocationOf(mergedId)
            );

            // Track ghost variables for cumulative checking
            ghost_mergeInputValue += totalInputValue;
            ghost_mergeOutputValue += outputValue;
            if (totalInputValue > outputValue) {
                ghost_mergeFeesPaid += totalInputValue - outputValue;
            }

            // === CRITICAL ASSERTIONS ===
            // 1. Fee is 2% max, so output should be at least 98% of input
            // Tolerance scales with number of flows (merged NFT can have many flows)
            if (totalInputValue > 1e18) {
                uint256 minExpectedOutput = (totalInputValue * 9800) / 10000;
                // Get number of flows from merged allocation for tolerance
                TVSManager.Allocation memory mergedAlloc = tvsManager
                    .getAllocationOf(mergedId);
                uint256 numFlows = mergedAlloc.amounts.length;
                uint256 tolerance = numFlows * 4 + 10;
                assert(outputValue + tolerance >= minExpectedOutput);
            }
            // 2. No value creation - output cannot exceed input
            // Use generous tolerance for multi-flow merges
            assert(outputValue <= totalInputValue + 100);

            // Add merged NFT and cleanup
            projectNfts.push(mergedId);
            allNftIds.push(mergedId);
            _removeFromProject(projectNfts, idx1 < idx2 ? idx1 : idx2);
            _removeFromProject(projectNfts, idx1 < idx2 ? idx2 - 1 : idx1 - 1);
            _removeFromAll(nftId1);
            _removeFromAll(nftId2);

            ghost_totalMerges++;
            ghost_totalBurned += 2;
            ghost_totalMinted++;
            ghost_totalMinted++;
        } catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    // === SPLIT ACTIONS ===

    function splitNft(uint256 nftSeed, uint256 percentage) external {
        if (allNftIds.length == 0) return;

        uint256 idx = nftSeed % allNftIds.length;
        uint256 nftId = allNftIds[idx];

        if (!_isOwnedByUs(nftId)) {
            _removeFromAll(nftId);
            return;
        }

        percentage = _bound(percentage, 1, 9999);
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = percentage;
        percentages[1] = 10000 - percentage;

        TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(nftId);
        uint256 projectId = alloc.projectId;

        // === VALUE CONSERVATION: Capture input value BEFORE split ===
        // Splits operate on REMAINING value (amounts - claimed), not total amounts
        uint256 inputValue = _sumRemainingAmounts(alloc);

        try tvsManager.splitTVS(percentages, nftId) returns (
            uint256,
            uint256[] memory newIds
        ) {
            // === VALUE CONSERVATION: Capture output values AFTER split ===
            uint256 totalOutputValue = 0;
            for (uint256 i = 0; i < newIds.length; i++) {
                TVSManager.Allocation memory newAlloc = tvsManager
                    .getAllocationOf(newIds[i]);
                totalOutputValue += _sumAmounts(newAlloc);
            }

            // Calculate fees: inputValue - totalOutputValue
            uint256 feePaid = 0;
            if (inputValue > totalOutputValue) {
                feePaid = inputValue - totalOutputValue;
            }

            // Track ghost variables
            ghost_splitInputValue += inputValue;
            ghost_splitOutputValue += totalOutputValue;
            ghost_splitFeesPaid += feePaid;

            // === CRITICAL ASSERTION: Value Conservation ===
            // Fee is 2% max, so output should be at least 98% of input
            // Tolerance scales with number of flows (each flow can have rounding error)
            if (inputValue > 1e18) {
                uint256 minExpectedOutput = (inputValue * 9800) / 10000; // 98%
                // Tolerance = numFlows * 2 (for 2 output NFTs) * 2 (for safety)
                uint256 numFlows = alloc.amounts.length;
                uint256 tolerance = numFlows * 4 + 10;
                assert(totalOutputValue + tolerance >= minExpectedOutput);
            }

            // === ASSERTION: No value creation ===
            // Tolerance scales with number of flows
            uint256 noCreateTolerance = alloc.amounts.length * 4 + 10;
            assert(totalOutputValue <= inputValue + noCreateTolerance);

            // Add new NFTs to appropriate project
            for (uint256 i = 0; i < newIds.length; i++) {
                if (projectId == 0) {
                    project0NftIds.push(newIds[i]);
                } else {
                    project1NftIds.push(newIds[i]);
                }
                allNftIds.push(newIds[i]);
                ghost_totalMinted++;
            }

            // Remove original NFT
            _removeFromAll(nftId);
            if (projectId == 0) {
                _removeNftFromArray(project0NftIds, nftId);
            } else {
                _removeNftFromArray(project1NftIds, nftId);
            }

            ghost_totalSplits++;
            ghost_totalBurned++;
        } catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    // === CLAIM ACTIONS ===

    function claimFromNft(uint256 nftSeed) external {
        if (allNftIds.length == 0) return;

        uint256 idx = nftSeed % allNftIds.length;
        uint256 nftId = allNftIds[idx];

        if (!_isOwnedByUs(nftId)) {
            _removeFromAll(nftId);
            return;
        }

        try tvsManager.claimTokens(nftId) {
            ghost_totalClaims++;
            ghost_totalClaims++;
        } catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    // === TIME ACTIONS ===
    // Multiple granularity levels for exploring vesting edge cases

    /// @notice Fine-grained time warp for exploring partial vesting states
    function warpTimeSmall(uint256 delta) external {
        delta = _bound(delta, 1, 100); // 1-100 seconds
        hevm.warp(block.timestamp + delta);
    }

    /// @notice Medium time warp around typical vesting period boundaries
    function warpTimeMedium(uint256 delta) external {
        delta = _bound(delta, 100, 2000); // 100-2000 seconds
        hevm.warp(block.timestamp + delta);
    }

    /// @notice Large time warp for completing vesting periods
    function warpTime(uint256 delta) external {
        delta = _bound(delta, 1 hours, 30 days); // 1 hour - 30 days
        hevm.warp(block.timestamp + delta);
    }

    /// @notice Warp past vesting/bidding end AND seed fresh projects to maintain state
    function warpToEndTimeAndRefresh() external {
        hevm.warp(block.timestamp + 8 days);

        // Seed fresh projects to keep state interesting
        _seedFreshProject(address(tokenA), 0);
        _seedFreshProject(address(tokenB), 1);
    }

    function _seedFreshProject(address token, uint256 projectTracker) internal {
        uint256 seedAmount = 200_000e18;
        uint256 vestingDuration = 5000; // 5000 seconds vesting

        try alignerz.launchRewardProject(token, seedAmount, vestingDuration) {
            // Get the new project ID (increments each launch)
            // Mint NFTs for the fresh project
            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 25_000e18;
            amounts[1] = 25_000e18;

            uint256[] memory vestingPeriods = new uint256[](2);
            vestingPeriods[0] = vestingDuration;
            vestingPeriods[1] = vestingDuration;

            // We can't know the exact projectId easily, but minting adds to pool
            // The NFTs will be tracked when they're successfully minted
            // The NFTs will be tracked when they're successfully minted
        } catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    // === BIDDING ACTIONS ===

    function launchBiddingProject(uint256 tokenSeed) external {
        // Use tokenA or tokenB for the bidding project
        address projectToken = (tokenSeed % 2 == 0)
            ? address(tokenA)
            : address(tokenB);
        // Use the other token as stablecoin
        address stablecoin = (tokenSeed % 2 == 0)
            ? address(tokenB)
            : address(tokenA);
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp + 7 days;
        bytes32 endTimeHash = keccak256(abi.encodePacked(endTime, tokenSeed));

        try
            alignerz.launchBiddingProject(
                projectToken,
                stablecoin,
                startTime,
                endTime,
                endTimeHash,
                false // whitelistStatus
            )
        {} catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    function createPool(
        uint256 projectSeed,
        uint256 allocationSeed,
        uint256 priceSeed
    ) external {
        uint256 projectId = projectSeed % 10;
        uint256 poolAllocation = _bound(allocationSeed, 1000e18, 100_000e18);
        uint256 tokenPrice = _bound(priceSeed, 1e18, 1000e18);

        // Approve tokens for pool
        tokenA.approve(address(alignerz), poolAllocation);
        tokenB.approve(address(alignerz), poolAllocation);

        try
            alignerz.createPool(projectId, poolAllocation, tokenPrice, false)
        {} catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    function placeBid(
        uint256 projectSeed,
        uint256 amountSeed,
        uint256 vestingPeriodSeed
    ) external {
        uint256 projectId = projectSeed % 10;
        uint256 bidAmount = _bound(amountSeed, 100e18, 10_000e18);
        uint256 vestingPeriod = _bound(vestingPeriodSeed, 1, 365 days);

        // Approve tokens for bid
        tokenA.approve(address(alignerz), bidAmount * 2);
        tokenB.approve(address(alignerz), bidAmount * 2);

        try alignerz.placeBid(projectId, bidAmount, vestingPeriod) {} catch (
            bytes memory reason
        ) {
            _checkError(reason);
        }
    }

    function updateBid(
        uint256 projectSeed,
        uint256 newAmountSeed,
        uint256 newVestingPeriodSeed
    ) external {
        uint256 projectId = projectSeed % 10;
        uint256 newAmount = _bound(newAmountSeed, 100e18, 50_000e18);
        uint256 newVestingPeriod = _bound(newVestingPeriodSeed, 1, 365 days);

        // Approve extra tokens for bid increase
        tokenA.approve(address(alignerz), newAmount * 2);
        tokenB.approve(address(alignerz), newAmount * 2);

        try
            alignerz.updateBid(projectId, newAmount, newVestingPeriod)
        {} catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    function finalizeBids(uint256 projectSeed) external {
        uint256 projectId = projectSeed % 10;
        try alignerz.finalizeBids(projectId) {} catch (bytes memory reason) {
            _checkError(reason);
        }
    }

    /// @notice Action: Warps time past a project's claim deadline
    function warpToAfterDeadline(uint256 projectSeed) external {
        uint256 projectId = projectSeed % 10;
        (, , , , , , , , bool closed, uint256 claimDeadline) = alignerz
            .biddingProjects(projectId);

        if (closed && claimDeadline > 0) {
            hevm.warp(claimDeadline + 1);
        }
    }

    /// @notice Action: Withdraws profit after deadline passed
    function withdrawPostDeadlineProfit(uint256 projectSeed) external {
        uint256 projectId = projectSeed % 10;
        try alignerz.withdrawPostDeadlineProfit(projectId) {} catch (
            bytes memory reason
        ) {
            _checkError(reason);
        }
    }

    // === INVARIANTS ===

    function invariant_nft_accounting() external view returns (bool) {
        // Total minted - burned should match active NFTs (approximately)
        // Note: splits create new NFTs, merges burn 2 and create 1
        return ghost_totalMinted >= ghost_totalBurned;
    }

    function invariant_no_negative_claims() external view returns (bool) {
        for (uint256 i = 0; i < allNftIds.length; i++) {
            uint256 nftId = allNftIds[i];
            try nft.ownerOf(nftId) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    nftId
                );
                for (uint256 j = 0; j < alloc.amounts.length; j++) {
                    if (alloc.claimedAmounts[j] > alloc.amounts[j]) {
                        return false;
                    }
                }
            } catch {}
        }
        return true;
    }

    function invariant_project_consistency() external view returns (bool) {
        // All project0 NFTs should have tokenA
        for (uint256 i = 0; i < project0NftIds.length; i++) {
            try nft.ownerOf(project0NftIds[i]) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    project0NftIds[i]
                );
                if (
                    address(alloc.token) != address(0) &&
                    address(alloc.token) != address(tokenA)
                ) {
                    return false;
                }
            } catch {}
        }
        // All project1 NFTs should have tokenB
        for (uint256 i = 0; i < project1NftIds.length; i++) {
            try nft.ownerOf(project1NftIds[i]) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    project1NftIds[i]
                );
                if (
                    address(alloc.token) != address(0) &&
                    address(alloc.token) != address(tokenB)
                ) {
                    return false;
                }
            } catch {}
        }
        return true;
    }

    /// @notice Global invariant: Merge fees never exceed 2% of input
    function invariant_merge_fee_bounds() external view returns (bool) {
        if (ghost_mergeInputValue == 0) return true;
        // Fee should not exceed 2% of total input
        uint256 maxAllowedFee = (ghost_mergeInputValue * 200) / 10000; // 2%
        return ghost_mergeFeesPaid <= maxAllowedFee;
    }

    /// @notice Global invariant: Split fees never exceed 2% of input
    function invariant_split_fee_bounds() external view returns (bool) {
        if (ghost_splitInputValue == 0) return true;
        // Fee should not exceed 2% of total input
        uint256 maxAllowedFee = (ghost_splitInputValue * 200) / 10000; // 2%
        return ghost_splitFeesPaid <= maxAllowedFee;
    }

    /// @notice Global invariant: Merge value conservation (cumulative)
    /// Input = Output + Fees (within rounding tolerance)
    function invariant_merge_value_conservation() external view returns (bool) {
        if (ghost_mergeInputValue == 0) return true;
        // ghost_mergeOutputValue + ghost_mergeFeesPaid should = ghost_mergeInputValue
        uint256 accounted = ghost_mergeOutputValue + ghost_mergeFeesPaid;
        // Allow 0.1% tolerance for rounding
        uint256 tolerance = ghost_mergeInputValue / 1000;
        if (accounted > ghost_mergeInputValue) {
            return accounted - ghost_mergeInputValue <= tolerance;
        }
        return ghost_mergeInputValue - accounted <= tolerance;
    }

    /// @notice Global invariant: Split value conservation (cumulative)
    function invariant_split_value_conservation() external view returns (bool) {
        if (ghost_splitInputValue == 0) return true;
        uint256 accounted = ghost_splitOutputValue + ghost_splitFeesPaid;
        uint256 tolerance = ghost_splitInputValue / 1000;
        if (accounted > ghost_splitInputValue) {
            return accounted - ghost_splitInputValue <= tolerance;
        }
        return ghost_splitInputValue - accounted <= tolerance;
    }

    /// @notice Invariant: TVSManager token balance >= total unclaimed allocations
    function invariant_total_token_balance() external view returns (bool) {
        // Calculate total unclaimed for tokenA
        uint256 totalUnclaimedA = 0;
        for (uint256 i = 0; i < allNftIds.length; i++) {
            uint256 nftId = allNftIds[i];
            try nft.ownerOf(nftId) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    nftId
                );
                if (address(alloc.token) == address(tokenA)) {
                    totalUnclaimedA += _sumRemainingAmounts(alloc);
                }
            } catch {}
        }

        // TVSManager should hold at least totalUnclaimedA of tokenA
        uint256 tvsBalanceA = tokenA.balanceOf(address(tvsManager));
        if (totalUnclaimedA > 0 && tvsBalanceA < totalUnclaimedA) {
            return false;
        }

        // Calculate total unclaimed for tokenB
        uint256 totalUnclaimedB = 0;
        for (uint256 i = 0; i < allNftIds.length; i++) {
            uint256 nftId = allNftIds[i];
            try nft.ownerOf(nftId) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    nftId
                );
                if (address(alloc.token) == address(tokenB)) {
                    totalUnclaimedB += _sumRemainingAmounts(alloc);
                }
            } catch {}
        }

        uint256 tvsBalanceB = tokenB.balanceOf(address(tvsManager));
        if (totalUnclaimedB > 0 && tvsBalanceB < totalUnclaimedB) {
            return false;
        }

        return true;
    }

    /// @notice Invariant: No duplicate NFT IDs in tracking arrays
    function invariant_no_duplicate_nfts() external view returns (bool) {
        // Check allNftIds for duplicates
        for (uint256 i = 0; i < allNftIds.length; i++) {
            for (uint256 j = i + 1; j < allNftIds.length; j++) {
                if (allNftIds[i] == allNftIds[j]) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @notice Invariant: Each NFT's allocation is non-zero if it exists
    function invariant_nft_allocations_valid() external view returns (bool) {
        for (uint256 i = 0; i < allNftIds.length; i++) {
            uint256 nftId = allNftIds[i];
            try nft.ownerOf(nftId) returns (address) {
                TVSManager.Allocation memory alloc = tvsManager.getAllocationOf(
                    nftId
                );
                // NFT should have at least one flow with non-zero amount
                if (alloc.amounts.length == 0) {
                    return false;
                }
                uint256 totalAmount = _sumAmounts(alloc);
                if (totalAmount == 0) {
                    return false;
                }
            } catch {}
        }
        return true;
    }

    /// @notice Invariant: Project stablecoin balance matches what Alignerz holds
    function invariant_project_solvency() external view returns (bool) {
        // Check for project 0 (Token A)
        // Simplified check: Sum of all project balances must be <= total balance held by Alignerz
        // We iterate assumed known projects range
        uint256 sumBalanceA = 0;
        uint256 sumBalanceB = 0;

        for (uint256 i = 0; i < 20; i++) {
            // Check first 20 potential projects
            (
                IERC20 token,
                IERC20 stablecoin,
                uint256 balance,
                ,
                ,
                ,
                ,
                ,
                ,

            ) = alignerz.biddingProjects(i);

            if (address(token) != address(0)) {
                if (address(stablecoin) == address(tokenA)) {
                    sumBalanceA += balance;
                } else if (address(stablecoin) == address(tokenB)) {
                    sumBalanceB += balance;
                }
            }
        }

        if (tokenA.balanceOf(address(alignerz)) < sumBalanceA) return false;
        if (tokenB.balanceOf(address(alignerz)) < sumBalanceB) return false;

        return true;
    }

    // === ERROR HANDLING ===

    function _checkError(bytes memory reason) internal {
        // If empty reason (panic/OOG), it's a critical failure
        if (reason.length == 0) {
            assert(false); // FAIL: Panic or OOG detected
        }

        bytes4 selector;
        if (reason.length >= 4) {
            assembly {
                selector := mload(add(reason, 32))
            }
        }

        // Whitelist of valid error selectors
        if (
            selector == 0x82b42900 || // Unauthorized (Ownable)
            selector == 0xe450d38c || // InsufficientBalance (ERC20)
            selector == 0xfb8f41b2 || // ERC20InsufficientAllowance
            selector == bytes4(keccak256("Invalid_Project_Id()")) ||
            selector == bytes4(keccak256("Invalid_PoolId()")) ||
            selector == bytes4(keccak256("Zero_Value()")) ||
            selector == bytes4(keccak256("Zero_Address()")) ||
            selector == bytes4(keccak256("Already_Claimed()")) ||
            selector == bytes4(keccak256("Caller_Should_Own_The_NFT()")) ||
            selector == bytes4(keccak256("Project_Still_Open()")) ||
            selector == bytes4(keccak256("Project_Already_Closed()")) ||
            selector == bytes4(keccak256("Deadline_Has_Passed()")) ||
            selector == bytes4(keccak256("Deadline_Has_Not_Passed()")) ||
            selector == bytes4(keccak256("Caller_Has_No_TVS_Allocation()")) ||
            selector == bytes4(keccak256("Insufficient_Balance()")) ||
            selector ==
            bytes4(keccak256("Starttime_Must_Be_Smaller_Than_Endtime()")) ||
            selector == bytes4(keccak256("Bidding_Period_Is_Not_Active()")) ||
            selector == bytes4(keccak256("New_Bid_Cannot_Be_Smaller()")) ||
            selector == bytes4(keccak256("Bid_Already_Exists()")) ||
            selector == bytes4(keccak256("User_Is_Not_whitelisted()")) ||
            selector == bytes4(keccak256("Too_Many_Flows()")) ||
            selector == bytes4(keccak256("Not_Enough_TVS_To_Merge()")) ||
            selector ==
            bytes4(keccak256("Percentages_Do_Not_Add_Up_To_One_Hundred()")) ||
            selector ==
            bytes4(keccak256("Splitting_Should_Not_Zero_Down_Amounts()")) ||
            selector ==
            bytes4(keccak256("New_Vesting_Period_Cannot_Be_Smaller()")) ||
            selector ==
            bytes4(keccak256("Amounts_Do_Not_Add_Up_To_Batch_Allocation()")) ||
            selector == bytes4(keccak256("Different_Tokens()")) ||
            selector == bytes4(keccak256("NFT_Has_Approvals()")) ||
            selector ==
            bytes4(keccak256("Project_Allocation_Is_Not_Set_Yet()")) ||
            selector ==
            bytes4(
                keccak256("Vesting_Period_Is_Not_Multiple_Of_The_Base_Value()")
            ) ||
            selector == bytes4(keccak256("No_Bid_Found()"))
        ) {
            return; // Valid error, ignore
        }

        // Catch Generic string errors "Error(string)"
        if (selector == bytes4(keccak256("Error(string)"))) {
            return; // Valid revert reason string
        }

        // If we get here, it's an UNEXPECTED error - log it before failing
        // Emit the selector so we can identify the unknown error
        emit UnknownRevert(selector, reason);
        assert(false); // FAIL: Unknown error detected
    }

    // Event to log unknown reverts for debugging
    event UnknownRevert(bytes4 selector, bytes reason);

    // === HELPER FUNCTIONS ===

    function _isOwnedByUs(uint256 nftId) internal view returns (bool) {
        try nft.ownerOf(nftId) returns (address owner_) {
            return owner_ == address(this);
        } catch {
            return false;
        }
    }

    function _removeFromProject(uint256[] storage arr, uint256 idx) internal {
        if (idx >= arr.length) return;
        arr[idx] = arr[arr.length - 1];
        arr.pop();
    }

    function _removeFromAll(uint256 nftId) internal {
        _removeNftFromArray(allNftIds, nftId);
    }

    function _removeNftFromArray(
        uint256[] storage arr,
        uint256 nftId
    ) internal {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == nftId) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                return;
            }
        }
    }

    /// @notice Helper to sum all amounts in an allocation
    function _sumAmounts(
        TVSManager.Allocation memory alloc
    ) internal pure returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < alloc.amounts.length; i++) {
            total += alloc.amounts[i];
        }
        return total;
    }

    /// @notice Helper to sum remaining (unclaimed) amounts in an allocation
    function _sumRemainingAmounts(
        TVSManager.Allocation memory alloc
    ) internal pure returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < alloc.amounts.length; i++) {
            total += alloc.amounts[i] - alloc.claimedAmounts[i];
        }
        return total;
    }

    function _bound(
        uint256 x,
        uint256 min,
        uint256 max
    ) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    // === VIEW FUNCTIONS FOR DEBUGGING ===

    function getProject0NftCount() external view returns (uint256) {
        return project0NftIds.length;
    }

    function getProject1NftCount() external view returns (uint256) {
        return project1NftIds.length;
    }

    function getAllNftCount() external view returns (uint256) {
        return allNftIds.length;
    }

    // === IERC721Receiver IMPLEMENTATION ===
    // Required to receive NFTs from safeMint during merge/split operations

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
