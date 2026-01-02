// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TVSCalculator} from "../../libraries/TVSCalculator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MergeSplitFeesManager} from "./feesManager/MergeSplitFeesManager.sol";
import {IAlignerzNFT} from "../../interfaces/IAlignerzNFT.sol";

/// @title TVSManager - A contract that allows users to manage their TVS
/// @notice This contract handles token claims, TVS splits and merges
/// @author 0xjarix | TVSManager
contract TVSManager is Initializable, UUPSUpgradeable, OwnableUpgradeable, MergeSplitFeesManager {
    using SafeERC20 for IERC20;

    // TYPEDEF
    struct Allocation {
        uint256[] amounts; // Amount of tokens committed for this allocation for all flows
        uint256[] vestingPeriods; // Chosen vesting duration in seconds for all flows
        uint256[] vestingStartTimes; // start time of the vesting for all flows
        uint256[] claimedAmounts; // Amounts of tokens claimed for this allocation for all flows
        bool[] claimedFlows; // Whether flow is claimed
        IERC20 token; // The TVS token
        uint256 projectId; // projectId
        bool isBiddingProject; // whether the TVS comes from a bidding or a reward project
        uint256 poolId; // id of the pool
    }

    // STATE VARIABLES
    uint256 public constant MAX_FLOW = 64;
    address public treasury;

    address public alignerz;

    bool private paused;

    IAlignerzNFT public nftContract;

    mapping(uint256 => Allocation) public allocationOf;

    // EVENTS
    event TokensClaimed(
        uint256 indexed projectId,
        uint256 indexed poolId,
        uint256 indexed nftId,
        bool isClaimed,
        uint256 claimTimestamp,
        address user,
        uint256[] claimedAmounts
    );

    event TVSsMerged(
        uint256 indexed projectId,
        bool indexed isBiddingProject,
        uint256[] nftIds,
        uint256 indexed mergedNftId,
        uint256[] amounts,
        uint256[] claimedAmounts,
        uint256[] vestingPeriods,
        uint256[] vestingStartTimes
    );

    event TVSSplit(
        uint256 indexed projectId,
        bool isBiddingProject,
        uint256 indexed splitNftId,
        uint256 indexed nftId,
        uint256[] vestingPeriods,
        uint256[] vestingStartTimes,
        uint256[] amounts,
        uint256[] claimedAmounts
    );

    event treasuryUpdated(address oldTreasury, address newTreasury);

    // ERRORS
    error Percentages_Do_Not_Add_Up_To_One_Hundred();
    error Caller_Should_Own_The_NFT();
    error Not_Enough_TVS_To_Merge();
    error Different_Tokens();
    error Only_Alignerz_Can_Call();
    error Splitting_Should_Not_Zero_Down_Amounts();
    error TVSManager_Is_Paused();
    error NFT_Has_Approvals();
    error Too_Many_Flows();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the TVSManager contract
    /// @param _nftContract Address of the NFT contract
    function initialize(address _nftContract) public initializer {
        __Ownable_init(msg.sender);
        __MergeSplitFeesManager_init();
        if (_nftContract == address(0)) revert();
        nftContract = IAlignerzNFT(_nftContract);
    }

    /// @notice modifier that prevents function calls when the contract is paused
    function _whenNotPaused() internal view {
        require(!paused, TVSManager_Is_Paused());
    }

    /// @notice returns true if the NFT has 0 approvals
    /// @param nftId The ID of the NFT
    function _hasZeroApprovals(uint256 nftId) internal view {
        require(nftContract.hasZeroApprovals(nftId), NFT_Has_Approvals());
    }

    /// @notice Allows the owner to pause the contract
    function pause() external onlyOwner {
        paused = true;
    }

    /// @notice Allows the owner to unpause the contract
    function unpause() external onlyOwner {
        paused = false;
    }

    /// @notice Allows the owner to set the address of the Alignerz contract once at deployment
    function setAlignerz(address _alignerz) external onlyOwner {
        alignerz = _alignerz;
    }

    /// @notice Allows the owner to set the address of the treasury
    /// @param newTreasury New treasury address
    function setTreasury(address newTreasury) external onlyOwner returns (bool) {
        if (newTreasury == address(0)) revert();
        address oldTreasury = treasury;
        if (newTreasury == oldTreasury) revert();
        treasury = newTreasury;

        emit treasuryUpdated(oldTreasury, newTreasury);
        return true;
    }

    /// @notice Allows the Alignerz contract to set the TVSManager's storage
    /// @param nftId NFT ID of the TVS
    /// @param _amount amount of tokens allocated to the TVS
    /// @param _vestingPeriod vesting period
    /// @param _vestingStartTime start time of the vesting period
    /// @param _token project's token
    /// @param _projectId ID of the project
    /// @param _isBiddingProject true if the project is a bidding project, false otherwise
    /// @param _poolId ID of the pool (0 if it's a reward project)
    function setTVS(
        uint256 nftId,
        uint256 _amount,
        uint256 _vestingPeriod,
        uint256 _vestingStartTime,
        IERC20 _token,
        uint256 _projectId,
        bool _isBiddingProject,
        uint256 _poolId
    ) external {
        require(msg.sender == address(alignerz), Only_Alignerz_Can_Call());
        allocationOf[nftId].amounts.push(_amount);
        allocationOf[nftId].vestingPeriods.push(_vestingPeriod);
        allocationOf[nftId].vestingStartTimes.push(_vestingStartTime);
        allocationOf[nftId].claimedAmounts.push(0);
        allocationOf[nftId].claimedFlows.push(false);
        allocationOf[nftId].token = _token;
        allocationOf[nftId].projectId = _projectId;
        allocationOf[nftId].isBiddingProject = _isBiddingProject;
        allocationOf[nftId].poolId = _poolId;
    }

    /// @notice Getter to retrieve the attributes of a TVS allocation
    /// @param nftId NFT ID of the TVS
    function getAllocationOf(uint256 nftId) public view returns (Allocation memory) {
        return allocationOf[nftId];
    }

    /// @notice Allows a user to claim tokens from his TVS
    /// @param nftId NFT ID of the TVS
    function claimTokens(uint256 nftId) external {
        _whenNotPaused();
        _hasZeroApprovals(nftId);
        address nftOwner = nftContract.extOwnerOf(nftId);
        require(msg.sender == nftOwner, Caller_Should_Own_The_NFT());
        Allocation storage allocation = allocationOf[nftId];
        IERC20 _token = allocation.token;
        uint256 nbOfFlows = allocation.vestingPeriods.length;
        uint256[] memory claimableAmounts = new uint256[](nbOfFlows);
        uint256 amountClaimed;
        uint256 flowsClaimed;
        for (uint256 i; i < nbOfFlows; i++) {
            if (allocation.claimedFlows[i]) {
                flowsClaimed++;
                continue;
            }
            uint256 claimableAmount = getClaimableAmount(allocation, i);

            allocation.claimedAmounts[i] += claimableAmount;
            if (allocation.claimedAmounts[i] == allocation.amounts[i]) {
                flowsClaimed++;
                allocation.claimedFlows[i] = true;
            }
            claimableAmounts[i] = claimableAmount;
            amountClaimed += claimableAmount;
        }
        bool isClaimed;
        if (flowsClaimed == nbOfFlows) {
            nftContract.burn(nftId);
            isClaimed = true;
        }
        _token.safeTransfer(msg.sender, amountClaimed);
        emit TokensClaimed(
            allocation.projectId, allocation.poolId, nftId, isClaimed, block.timestamp, msg.sender, claimableAmounts
        );
    }

    /// @notice getter for claimable amount for a certain allocation's flow index
    /// @param allocation the TVS allocation
    /// @param flowIndex index of the token flow
    function getClaimableAmount(Allocation memory allocation, uint256 flowIndex)
        public
        view
        returns (uint256 claimableAmount)
    {
        uint256 vestingPeriod = allocation.vestingPeriods[flowIndex];
        uint256 vestingStartTime = allocation.vestingStartTimes[flowIndex];
        uint256 amount = allocation.amounts[flowIndex];
        uint256 claimedAmount = allocation.claimedAmounts[flowIndex];
        if (block.timestamp < vestingPeriod + vestingStartTime) {
            claimableAmount = ((block.timestamp - vestingStartTime) * amount / vestingPeriod) - claimedAmount;
        } else {
            claimableAmount = amount - claimedAmount;
        }
        return claimableAmount;
    }

    /// @notice Allows a user to split his TVS
    /// @param percentages % in basis point of the amounts that will be allocated in the TVSs after the split
    /// @param splitNftId NFT ID of the TVS to split
    function splitTVS(uint256[] calldata percentages, uint256 splitNftId)
        external
        returns (uint256, uint256[] memory)
    {
        _whenNotPaused();
        address nftOwner = nftContract.extOwnerOf(splitNftId);
        require(msg.sender == nftOwner, Caller_Should_Own_The_NFT());

        Allocation memory allocation = allocationOf[splitNftId];

        IERC20 _token = allocation.token;
        uint256 nbOfFlows = allocation.amounts.length;
        if (splitFeeRate > 0) {
            (uint256 feeAmount, uint256[] memory newAmounts) =
                TVSCalculator.calculateFeeAndNewClaimedSecondsForOneTVS(allocation, splitFeeRate);
            allocation.amounts = newAmounts;
            _token.safeTransfer(treasury, feeAmount);
        }
        uint256 nbOfTVS = percentages.length;
        nftContract.burn(splitNftId);

        // new NFT IDs except the original one
        uint256[] memory newNftIds = new uint256[](nbOfTVS);

        uint256 sumOfPercentages;
        for (uint256 i; i < nbOfTVS;) {
            uint256 percentage = percentages[i];
            if (percentage == 0) revert();
            sumOfPercentages += percentage;

            uint256 nftId = nftContract.mint(msg.sender);
            newNftIds[i] = nftId;
            (
                allocationOf[nftId].vestingPeriods,
                allocationOf[nftId].vestingStartTimes,
                allocationOf[nftId].amounts,
                allocationOf[nftId].claimedAmounts,
                allocationOf[nftId].claimedFlows
            ) = TVSCalculator.computeSplitArrays(allocation, percentage, nbOfFlows);
            allocationOf[nftId].token = _token;
            allocationOf[nftId].poolId = allocation.poolId;
            allocationOf[nftId].projectId = allocation.projectId;
            allocationOf[nftId].isBiddingProject = allocation.isBiddingProject;
            Allocation storage newAlloc = allocationOf[nftId];
            emit TVSSplit(
                allocation.projectId,
                allocation.isBiddingProject,
                splitNftId,
                nftId,
                newAlloc.vestingPeriods,
                newAlloc.vestingStartTimes,
                newAlloc.amounts,
                newAlloc.claimedAmounts
            );
            unchecked {
                ++i;
            }
        }
        require(sumOfPercentages == BASIS_POINT, Percentages_Do_Not_Add_Up_To_One_Hundred());
        return (splitNftId, newNftIds);
    }

    /// @notice Allows a user to merge his TVSs
    /// @param nftIds List of the NFT IDs of the TVSs to merge
    function mergeTVS(uint256[] calldata nftIds) external returns (uint256) {
        _whenNotPaused();
        IERC20 token = allocationOf[nftIds[0]].token;

        uint256 nbOfNFTs = nftIds.length;
        require(nbOfNFTs > 1, Not_Enough_TVS_To_Merge());

        uint256 mergedNftId = nftContract.mint(msg.sender);
        Allocation storage mergedTVS = allocationOf[mergedNftId];
        mergedTVS.token = allocationOf[nftIds[0]].token;
        mergedTVS.projectId = allocationOf[nftIds[0]].projectId;
        mergedTVS.isBiddingProject = allocationOf[nftIds[0]].isBiddingProject;
        mergedTVS.poolId = allocationOf[nftIds[0]].poolId;
        for (uint256 i; i < nbOfNFTs;) {
            _merge(mergedTVS, nftIds[i], token);
            unchecked {
                ++i;
            }
        }
        Allocation memory mergedTVSMemory = mergedTVS;
        if (mergeFeeRate > 0) {
            (uint256 feeAmount, uint256[] memory newAmounts) =
                TVSCalculator.calculateFeeAndNewClaimedSecondsForOneTVS(mergedTVSMemory, mergeFeeRate);
            mergedTVS.amounts = newAmounts;
            token.safeTransfer(treasury, feeAmount);
        }
        require(mergedTVSMemory.amounts.length <= MAX_FLOW, Too_Many_Flows());
        emit TVSsMerged(
            mergedTVSMemory.projectId,
            mergedTVSMemory.isBiddingProject,
            nftIds,
            mergedNftId,
            mergedTVS.amounts,
            mergedTVSMemory.claimedAmounts,
            mergedTVSMemory.vestingPeriods,
            mergedTVSMemory.vestingStartTimes
        );
        return mergedNftId;
    }

    function _merge(Allocation storage mergedTVS, uint256 nftId, IERC20 token) internal {
        require(msg.sender == nftContract.extOwnerOf(nftId), Caller_Should_Own_The_NFT());
        Allocation memory TVSToMerge = allocationOf[nftId];
        IERC20 tokenToMerge = TVSToMerge.token;
        require(address(token) == address(tokenToMerge), Different_Tokens());

        uint256 nbOfFlowsTVSToMerge = TVSToMerge.amounts.length;
        for (uint256 j = 0; j < nbOfFlowsTVSToMerge;) {
            mergedTVS.amounts.push(TVSToMerge.amounts[j]);
            mergedTVS.vestingPeriods.push(TVSToMerge.vestingPeriods[j]);
            mergedTVS.vestingStartTimes.push(TVSToMerge.vestingStartTimes[j]);
            mergedTVS.claimedAmounts.push(TVSToMerge.claimedAmounts[j]);
            mergedTVS.claimedFlows.push(TVSToMerge.claimedFlows[j]);
            unchecked {
                ++j;
            }
        }
        nftContract.burn(nftId);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
