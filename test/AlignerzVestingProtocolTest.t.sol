// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {A26Z} from "../src/contracts/token/A26Z.sol";
import {AlignerzNFT} from "../src/contracts/nft/AlignerzNFT.sol";
import {MockUSD} from "../src/MockUSD.sol";
import {Alignerz} from "../src/contracts/vesting/Alignerz.sol";
import {TVSManager} from "../src/contracts/vesting/TVSManager.sol";
import {ITVSManager} from "../src/interfaces/ITVSManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CompleteMerkle} from "murky/src/CompleteMerkle.sol";

contract AlignerzVestingProtocolTest is Test {
    A26Z public token;
    AlignerzNFT public nft;
    MockUSD public usdt;
    Alignerz public alignerz;
    TVSManager public tvsManager;
    ITVSManager public iTvsManager;

    address public owner;
    address[] public bidders;

    // Constants
    uint256 constant NUM_BIDDERS = 20;
    uint256 constant TOKEN_AMOUNT = 26_000_000 ether;
    uint256 constant BIDDER_USD = 1_000_000;
    uint256 constant PROJECT_ID = 0;

    // Project structure for organization
    struct BidInfo {
        address bidder;
        uint256 amount;
        uint256 vestingPeriod;
        uint256 poolId;
        bool accepted;
    }

    // Track allocated bids and their proofs
    mapping(address => bytes32[]) public bidderProofs;
    mapping(address => uint256) public bidderPoolIds;
    mapping(address => uint256) public bidderNFTIds;
    bytes32 public refundRoot;

    function setUp() public {
        owner = address(this);
        vm.deal(owner, 100 ether);

        // Deploy contracts
        usdt = new MockUSD();
        token = new A26Z("A26Z", "A26Z");
        nft = new AlignerzNFT("AlignerzNFT", "AZNFT", "https://nft.Alignerz.bid/");
        address TVSManagerImplementation = address(new TVSManager());
        address TVSManagerProxy =
            address(new ERC1967Proxy(TVSManagerImplementation, abi.encodeCall(TVSManager.initialize, (address(nft)))));

        tvsManager = TVSManager(payable(TVSManagerProxy));
        iTvsManager = ITVSManager(address(tvsManager));
        console.log("TVSManager deployed at:", address(tvsManager));

        nft.addMinter(TVSManagerProxy);
        console.logString("Set AlignerzTVSManager as minter for AlignerzNFT");

        address alignerzImplementation = address(new Alignerz());
        address alignerzProxy = address(
            new ERC1967Proxy(
                alignerzImplementation, abi.encodeCall(Alignerz.initialize, (address(nft), TVSManagerProxy))
            )
        );

        alignerz = Alignerz(payable(alignerzProxy));
        console.log("AlignerzVesting deployed at:", address(alignerz));

        nft.addMinter(alignerzProxy);
        console.logString("Set AlignerzVesting as minter for AlignerzNFT");

        tvsManager.setTreasury(owner);
        tvsManager.setAlignerz(alignerzProxy);

        nft.transferOwnership(owner);
        usdt.transferOwnership(owner);
        token.transferOwnership(owner);
        alignerz.transferOwnership(owner);
        tvsManager.transferOwnership(owner);

        // Create bidders with ETH and USDT
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            address bidder = makeAddr(string.concat("bidder", vm.toString(i)));
            vm.prank(owner);
            usdt.transfer(bidder, BIDDER_USD);
            bidders.push(bidder);
        }

        // Approve tokens for alignerz contract
        vm.prank(owner);
        token.approve(address(alignerz), TOKEN_AMOUNT);
        token.approve(address(tvsManager), TOKEN_AMOUNT);
    }

    // Helper function to create a leaf node for the merkle tree
    function getLeaf(address bidder, uint256 amount, uint256 projectId, uint256 poolId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(bidder, amount, projectId, poolId));
    }

    // Helper for generating merkle proofs
    function generateMerkleProofs(BidInfo[] memory bids, uint256 poolId) internal returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](bids.length);
        uint256 leafCount = 0;

        // Create leaves for each bid in this pool
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].poolId == poolId && bids[i].accepted) {
                leaves[leafCount] = getLeaf(bids[i].bidder, bids[i].amount, PROJECT_ID, poolId);

                bidderPoolIds[bids[i].bidder] = poolId;
                leafCount++;
            }
        }

        CompleteMerkle m = new CompleteMerkle();
        bytes32 root = m.getRoot(leaves);
        uint256 indexTracker = 0;
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].poolId == poolId && bids[i].accepted) {
                bytes32[] memory proof = m.getProof(leaves, indexTracker);
                bidderProofs[bids[i].bidder] = proof;
                indexTracker++;
            }
        }

        return root;
    }

    // Helper for generating refund proofs
    function generateRefundProofs(BidInfo[] memory bids) internal returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](bids.length);
        uint256 leafCount = 0;
        uint256 poolId = 0;

        // Create leaves for each bid in this pool
        for (uint256 i = 0; i < bids.length; i++) {
            if (!bids[i].accepted) {
                leaves[leafCount] = getLeaf(bids[i].bidder, bids[i].amount, PROJECT_ID, poolId);

                bidderPoolIds[bids[i].bidder] = poolId;
                leafCount++;
            }
        }

        CompleteMerkle m = new CompleteMerkle();
        bytes32 root = m.getRoot(leaves);
        uint256 indexTracker = 0;
        for (uint256 i = 0; i < bids.length; i++) {
            if (!bids[i].accepted) {
                bytes32[] memory proof = m.getProof(leaves, indexTracker);
                bidderProofs[bids[i].bidder] = proof;
                indexTracker++;
            }
        }

        return root;
    }

    function test_CompleteBiddingVestingFlow() public {
        vm.startPrank(owner);
        alignerz.setVestingPeriodDivisor(1);

        // 1. Launch project
        vm.startPrank(owner);
        alignerz.launchBiddingProject(
            address(token), address(usdt), block.timestamp, block.timestamp + 1_000_000, "0x0", true
        );

        // 2. Create multiple pools with different prices
        alignerz.createPool(PROJECT_ID, 3_000_000 ether, 0.01 ether, true);
        alignerz.createPool(PROJECT_ID, 3_000_000 ether, 0.02 ether, false);
        alignerz.createPool(PROJECT_ID, 4_000_000 ether, 0.03 ether, false);

        // 3. Place bids from different whitelisted users
        alignerz.addUsersToWhitelist(bidders, PROJECT_ID);
        vm.stopPrank();
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            vm.startPrank(bidders[i]);

            // Approve and place bid
            usdt.approve(address(alignerz), BIDDER_USD);

            // Different vesting periods to test variety
            uint256 vestingPeriod = (i % 3 == 0) ? 90 days : (i % 3 == 1) ? 180 days : 365 days;

            alignerz.placeBid(PROJECT_ID, BIDDER_USD, vestingPeriod);
            vm.stopPrank();
        }

        // 4. Update some bids
        vm.prank(bidders[0]);
        alignerz.updateBid(PROJECT_ID, BIDDER_USD, 180 days);

        // 5. Prepare bid allocations (this would be done off-chain)
        BidInfo[] memory allBids = new BidInfo[](NUM_BIDDERS);

        // Simulate off-chain allocation process
        for (uint256 i = 0; i < NUM_BIDDERS; i++) {
            // Assign bids to pools (in reality, this would be based on some algorithm)
            uint256 poolId = i % 3;
            bool accepted = i < 15; // First 15 bidders are accepted

            allBids[i] = BidInfo({
                bidder: bidders[i],
                amount: BIDDER_USD, // For simplicity, all bids are the same amount
                vestingPeriod: (i % 3 == 0) ? 90 days : (i % 3 == 1) ? 180 days : 365 days,
                poolId: poolId,
                accepted: accepted
            });
        }

        // 6. Generate merkle roots for each pool
        bytes32[] memory poolRoots = new bytes32[](3);
        for (uint256 poolId = 0; poolId < 3; poolId++) {
            poolRoots[poolId] = generateMerkleProofs(allBids, poolId);
        }

        // 7. Generate refund proofs
        refundRoot = generateRefundProofs(allBids);

        // 8. Finalize project with merkle roots
        vm.prank(owner);
        alignerz.finalizeBids(PROJECT_ID);
        alignerz.setProjectAllocations(PROJECT_ID, refundRoot, poolRoots, 60);
        uint256[] memory nftIds = new uint256[](15);
        // 9. Users claim NFTs with proofs
        for (uint256 i = 0; i < 15; i++) {
            // Only accepted bidders
            address bidder = bidders[i];
            uint256 poolId = bidderPoolIds[bidder];

            vm.prank(bidder);
            uint256 nftId = alignerz.claimNFT(PROJECT_ID, poolId, BIDDER_USD, bidderProofs[bidder]);
            nftIds[i] = nftId;
            vm.prank(bidder);
            //(uint256 oldNft, uint256 newNft) = vesting.splitTVS(PROJECT_ID, nftId, 5000);
            //assertEq(oldNft, nftId);
            bidderNFTIds[bidder] = nftId;

            // Verify NFT ownership
            assertEq(nft.ownerOf(nftId), bidder);
        }

        // 10. Some users try to claim refunds
        for (uint256 i = 15; i < NUM_BIDDERS; i++) {
            // Only Refunded bidders
            address bidder = bidders[i];
            vm.prank(bidder);
            alignerz.claimRefund(PROJECT_ID, BIDDER_USD, bidderProofs[bidder]);

            // Verify USDT was returned
            assertEq(usdt.balanceOf(bidders[i]), BIDDER_USD);
        }

        // 11. Fast forward time to simulate vesting period
        vm.warp(block.timestamp + 60 days);

        // 12. Users claim tokens after vesting period
        for (uint256 i = 0; i < 15; i++) {
            address bidder = bidders[i];
            //uint256 nftId = bidderNFTIds[bidder];

            uint256 tokenBalanceBefore = token.balanceOf(bidder);

            vm.prank(bidder);
            tvsManager.claimTokens(nftIds[i]);

            uint256 tokenBalanceAfter = token.balanceOf(bidder);
            assertTrue(tokenBalanceAfter > tokenBalanceBefore, "No tokens claimed");
        }

        // 13. Fast forward more time to simulate complete vesting
        vm.warp(block.timestamp + 365 days);

        // 14. Users claim remaining tokens
        for (uint256 i = 0; i < 15; i++) {
            address bidder = bidders[i];
            uint256 nftId = bidderNFTIds[bidder];

            // Skip if NFT was already burned due to full claim
            if (nftId == 0) continue;

            try nft.ownerOf(nftId) returns (address ownerOf) {
                uint256[] memory percentages = new uint256[](2);
                percentages[0] = 5000;
                percentages[1] = 5000;
                uint256[] memory newNftIds = new uint256[](1);
                //uint256[] memory NFTIdsOfTVSPostMerge = new uint256[](6);
                vm.startPrank(ownerOf);
                skip(5000);
                (, newNftIds) = tvsManager.splitTVS(percentages, nftId);
                skip(5000);
                uint256 postMergeNftId = tvsManager.mergeTVS(newNftIds);
                skip(5000);
                tvsManager.claimTokens(postMergeNftId);
                vm.stopPrank(); /*
                for(uint j; j < 6; j++) {
                    skip(5000);
                    vm.prank(ownerOf);
                    (,newNftIds) = tvsManager.splitTVS(percentages, nftId);
                    skip(5000);
                    vm.prank(ownerOf);
                    uint256 postMergeNftId = tvsManager.mergeTVS(newNftIds);
                    NFTIdsOfTVSPostMerge[j] = postMergeNftId;
                }
                uint256[] memory perc = new uint256[](6);
                perc[0] = 2000;
                perc[1] = 2000;
                perc[2] = 2000;
                perc[3] = 2000;
                perc[4] = 1000;
                perc[5] = 1000;
                vm.prank(ownerOf);
                uint256 lastMergeNftId = tvsManager.mergeTVS(NFTIdsOfTVSPostMerge);
                skip(5000);
                vm.prank(ownerOf);
                tvsManager.claimTokens(lastMergeNftId);
                skip(5000);
                vm.prank(ownerOf);
                tvsManager.splitTVS(perc, lastMergeNftId);*/
            } catch {
                // NFT was already burned, which means tokens were fully claimed
            }
        }

        // 15. Update project allocations (optional test)
        bytes32[] memory newPoolRoots = new bytes32[](3);
        for (uint256 i = 0; i < 3; i++) {
            newPoolRoots[i] = keccak256(abi.encodePacked("new_pool_root", i));
        }

        vm.prank(owner);
        alignerz.withdrawPostDeadlineProfit(PROJECT_ID);
    }

    function test_MultipleBiddingProjectsFlow() public {
        vm.startPrank(owner);
        alignerz.setVestingPeriodDivisor(1);
        // Similar to the complete flow but with multiple projects
        // This demonstrates the contract's ability to handle multiple projects simultaneously

        // Setup first project
        vm.startPrank(owner);
        alignerz.launchBiddingProject(
            address(token), address(usdt), block.timestamp, block.timestamp + 1_000_000, "0x0", true
        );
        alignerz.createPool(0, 3_000_000 ether, 0.01 ether, true);
        alignerz.addUsersToWhitelist(bidders, 0);
        vm.stopPrank();

        // Setup second project
        vm.startPrank(owner);
        alignerz.launchBiddingProject(
            address(token), address(usdt), block.timestamp + 100, block.timestamp + 1_100_000, "0x0", true
        );
        alignerz.createPool(1, 3_000_000 ether, 0.015 ether, false);
        alignerz.addUsersToWhitelist(bidders, 1);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);
        // Place bids for both projects
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(bidders[i]);
            usdt.approve(address(alignerz), BIDDER_USD);
            alignerz.placeBid(0, BIDDER_USD / 2, 90 days);
            vm.stopPrank();

            vm.startPrank(bidders[i + 10]);
            usdt.approve(address(alignerz), BIDDER_USD);
            alignerz.placeBid(1, BIDDER_USD / 2, 180 days);
            vm.stopPrank();
        }

        // Simplified allocation for both projects
        bytes32[] memory poolRootsProject0 = new bytes32[](1);
        poolRootsProject0[0] = keccak256(abi.encodePacked("project0_pool0"));

        bytes32[] memory poolRootsProject1 = new bytes32[](1);
        poolRootsProject1[0] = keccak256(abi.encodePacked("project1_pool0"));

        // Finalize both projects
        vm.startPrank(owner);
        alignerz.finalizeBids(0);
        alignerz.finalizeBids(1);
        vm.stopPrank();
    }

    function test_RewardProjectNormalFlow() public {
        vm.startPrank(owner);
        alignerz.launchRewardProject(address(token));
        uint256[] memory amounts = new uint256[](1000);
        address[] memory kols = new address[](1000);
        for (uint256 i; i < 1000; i++) {
            amounts[i] = 3000 ether;
        }
        for (uint256 i; i < 1000; i++) {
            kols[i] = address(uint160(i + 1));
        }
        token.approve(address(alignerz), type(uint256).max);
        alignerz.setTVSAllocation(0, 3_000_000 ether, 2_592_000, kols, amounts);
        vm.stopPrank();
        uint256[] memory nftIds = new uint256[](1000);
        for (uint256 i; i < 1000; i++) {
            vm.prank(kols[i]);
            nftIds[i] = alignerz.claimRewardTVS(0);
        }
        skip(5000);
        for (uint256 i; i < 1000; i++) {
            vm.prank(kols[i]);
            tvsManager.claimTokens(nftIds[i]);
        }
        skip(500);
        for (uint256 i; i < 10; i++) {
            uint256[] memory percentages = new uint256[](2);
            percentages[0] = 5000;
            percentages[1] = 5000;
            uint256[] memory newNftIds = new uint256[](1);
            address kol = kols[i];
            uint256 nftId = nftIds[i];
            vm.startPrank(kol);
            (, newNftIds) = tvsManager.splitTVS(percentages, nftId);
            tvsManager.mergeTVS(newNftIds);
            vm.stopPrank();
        }
    }

    function test_RewardProjectFlowZeroMonth() public {
        vm.startPrank(owner);
        alignerz.launchRewardProject(address(token));
        uint256[] memory amounts = new uint256[](1000);
        address[] memory kols = new address[](1000);
        for (uint256 i; i < 1000; i++) {
            amounts[i] = 3000 ether;
        }
        for (uint256 i; i < 1000; i++) {
            kols[i] = address(uint160(i + 1));
        }
        token.approve(address(alignerz), type(uint256).max);
        alignerz.setTVSAllocation(0, 3_000_000 ether, 1, kols, amounts);
        vm.stopPrank();
        uint256[] memory nftIds = new uint256[](1000);
        for (uint256 i; i < 1000; i++) {
            skip(500);
            vm.prank(kols[i]);
            nftIds[i] = alignerz.claimRewardTVS(0);
        }
        address splitter = kols[5];
        for (uint256 i; i < 5; i++) {
            vm.prank(kols[i]);
            nft.safeTransferFrom(kols[i], splitter, nftIds[i]);
        }
        skip(500);
        uint256[] memory percentages = new uint256[](6);
        percentages[0] = 2000;
        percentages[1] = 2000;
        percentages[2] = 2000;
        percentages[3] = 2000;
        percentages[4] = 1000;
        percentages[5] = 1000;
        vm.startPrank(splitter);
        uint256[] memory NFTIdsOfTVSPostMerge = new uint256[](6);
        for (uint256 j; j < 6; j++) {
            uint256[] memory newNftIds = new uint256[](6);
            (, newNftIds) = tvsManager.splitTVS(percentages, nftIds[j]);
            skip(500);
            uint256 newNFTId = tvsManager.mergeTVS(newNftIds);
            NFTIdsOfTVSPostMerge[j] = newNFTId;
        }
        skip(500);
        uint256 NFTPostMerge = tvsManager.mergeTVS(NFTIdsOfTVSPostMerge);
        skip(500);
        tvsManager.claimTokens(NFTPostMerge);
        vm.stopPrank();
    }
    /*
    function test_RewardMultipleProjectFlowsAndCrossProjectMerge() public {
        vm.startPrank(owner);
        alignerz.launchRewardProject(address(token));
        alignerz.launchRewardProject(address(token));
        skip(500);
        uint256[] memory amounts = new uint256[](1000);
        address[] memory kols = new address[](1000);
        for(uint i; i < 1000; i++){
            amounts[i] = 3000 ether;
        }
        for(uint i; i < 1000; i++){
            kols[i] = address(uint160(i+1));
        }
        token.approve(address(alignerz), type(uint256).max);
        alignerz.setTVSAllocation(0, 3_000_000 ether, 1, kols, amounts);
        alignerz.setTVSAllocation(1, 3_000_000 ether, 2_592_000, kols, amounts);
        vm.stopPrank();
        skip(500);
        uint256[] memory nftIds = new uint256[](1000);
        uint256[] memory nftIdsBis = new uint256[](1000);
        for(uint i; i < 1000; i++) {
            vm.startPrank(kols[i]);
            nftIds[i] = alignerz.claimRewardTVS(0);
            nftIdsBis[i] = alignerz.claimRewardTVS(1);
            vm.stopPrank();
        }
        skip(500);
        address splitter = kols[5];
        for(uint i; i < 5; i++) {
            vm.startPrank(kols[i]);
            nft.safeTransferFrom(kols[i], splitter, nftIds[i]);
            nft.safeTransferFrom(kols[i], splitter, nftIdsBis[i]);
            vm.stopPrank();
        }
        skip(500);

        uint256[] memory percentages = new uint256[](6);
        percentages[0] = 2000;
        percentages[1] = 2000;
        percentages[2] = 2000;
        percentages[3] = 2000;
        percentages[4] = 1000;
        percentages[5] = 1000;
        vm.startPrank(splitter);
        uint256[] memory NFTsMergedInto = new uint256[](5);
        uint256[] memory NFTsMergedIntoBis = new uint256[](5);
        for(uint j; j < 5; j++) {
            uint256[] memory newNftIds = new uint256[](6);
            uint256[] memory newNftIdsBis = new uint256[](6);
            (,newNftIds) = tvsManager.splitTVS(percentages, nftIds[j]);
            (,newNftIdsBis) = tvsManager.splitTVS(percentages, nftIdsBis[j]);
            uint256 lenToMerge = newNftIds.length - 1;
            uint256[] memory nftIdsToMerge = new uint256[](lenToMerge);
            uint256[] memory nftIdsToMergeBis = new uint256[](lenToMerge);
            for(uint256 k; k < lenToMerge; k++) {
                nftIdsToMerge[k] = newNftIds[k+1];
                nftIdsToMergeBis[k] = newNftIdsBis[k+1];
            }
            skip(500);
            NFTsMergedInto[j] = tvsManager.mergeTVS(newNftIds[0], nftIdsToMerge);
            NFTsMergedIntoBis[j] = tvsManager.mergeTVS(newNftIdsBis[0], nftIdsToMergeBis);
        }
        skip(500);
        uint256 lenToMerge = NFTsMergedInto.length - 1;
        uint256[] memory nftIdsToMerge = new uint256[](lenToMerge);
        uint256[] memory nftIdsToMergeBis = new uint256[](lenToMerge);
        for(uint256 k; k < lenToMerge; k++) {
            nftIdsToMerge[k] = NFTsMergedInto[k+1];
            nftIdsToMergeBis[k] = NFTsMergedIntoBis[k+1];
        }
        uint256 NFTPostMerge = tvsManager.mergeTVS(NFTsMergedInto[0], nftIdsToMerge);
        uint256 NFTPostMergeBis = tvsManager.mergeTVS(NFTsMergedIntoBis[0], nftIdsToMergeBis);
        skip(500);
        uint256[] memory crossProjectMerge = new uint256[](1);
        crossProjectMerge[0] = NFTPostMergeBis;
        tvsManager.mergeTVS(NFTPostMerge, crossProjectMerge);
        skip(500);
        tvsManager.claimTokens(NFTPostMerge);
        vm.stopPrank();
    }*/
}
