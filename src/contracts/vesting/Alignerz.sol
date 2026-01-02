// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {WhitelistManager} from "./whitelistManager/WhitelistManager.sol";
import {BiddingFeesManager} from "./feesManager/BiddingFeesManager.sol";
import {IAlignerzNFT} from "../../interfaces/IAlignerzNFT.sol";
import {ITVSManager} from "../../interfaces/ITVSManager.sol";

/// @title Alignerz - A contract to launch bidding and reward projects
/// @notice This contract manages KOLs' TVS rewards, bidders' refunds and TVS allocation
/// @author 0xjarix | Alignerz
contract Alignerz is Initializable, UUPSUpgradeable, OwnableUpgradeable, WhitelistManager, BiddingFeesManager {
    using SafeERC20 for IERC20;
    /// @notice Represents a project with its token and vesting configuration
    /// @dev Contains mappings for pools and bids, along with projects parameters

    // TYPE DECLARATIONS
    struct RewardProject {
        IERC20 token; // The TVS token
        uint256 vestingPeriod; // The vesting period is the same for all KOLs
        uint256 startTime; // startTime of the vesting periods
        mapping(address => uint256) kolTVSRewards; // Mapping to track the allocated TVS rewards for each KOL
        mapping(address => uint256) kolTVSIndexOf; // Mapping to track the KOL address index position inside kolTVSAddresses
        address[] kolTVSAddresses; // array of kol addresses that are yet to claim TVS allocation
    }

    struct BiddingProject {
        IERC20 token; // The token being vested
        IERC20 stablecoin; // The token being used for bidding
        uint256 totalStablecoinBalance; // total Stablecoin Balance in the biddingProject
        uint256 poolCount; // Number of vesting pools in the biddingProject
        uint256 startTime; // Start time of the bidding period
        uint256 endTime; // End time of the bidding period and start time of the vesting periods
        mapping(uint256 => VestingPool) vestingPools; // Mapping of pool ID to pool details
        mapping(address => Bid) bids; // Mapping of bidder address to bid details
        bytes32 refundRoot; // Merkle root for refunded bids
        bytes32 endTimeHash; // has depicting the projected biddingProject end time (hidden from end user till biddingProject is closed)
        bool closed; // Whether bidding is closed
        uint256 claimDeadline; // deadline after which it's impossible for users to claim a refund
    }

    /// @notice Represents a TVS when it's first claimed
    struct TVSParams {
        uint256 nftId;
        uint256 amount;
        uint256 vestingPeriod;
        uint256 vestingStartTime;
        IERC20 token;
        uint256 projectId;
        bool isBiddingProject;
        uint256 poolId;
    }

    /// @notice Represents a vesting pool within a biddingProject
    /// @dev Contains allocation and vesting parameters for a specific pool
    struct VestingPool {
        bytes32 merkleRoot; // Merkle root for allocated bids
        bool hasExtraRefund; // whether pool refunds the winners as well
    }

    /// @notice Represents a bid placed by a user
    /// @dev Tracks the bid status and vesting progress
    struct Bid {
        uint256 amount; // Amount of stablecoin committed
        uint256 vestingPeriod; // Chosen vesting duration in seconds
    }

    // STATE VARIABLES
    /// @notice Total number of bidding biddingProjects created
    uint256 public biddingProjectCount;

    /// @notice Total number of reward biddingProjects created
    uint256 public rewardProjectCount;

    /// @notice vesting period can only be multiples of this value
    uint256 public vestingPeriodDivisor;

    /// @notice address of the contract that will allow user to manage their TVS (split / Merge / Claim Tokens)
    ITVSManager public TVSManager;

    /// @notice The NFT contract used for minting vesting certificates
    IAlignerzNFT public nftContract;

    /// @notice Mapping of biddingProject ID to BiddingProject details
    mapping(uint256 => BiddingProject) public biddingProjects;

    /// @notice Mapping of Reward biddingProject ID to Reward BiddingProject details
    mapping(uint256 => RewardProject) public rewardProjects;

    /// @notice Mapping to track claimed refunds
    mapping(bytes32 => bool) public claimedRefund;

    /// @notice Mapping to track claimed NFT
    mapping(bytes32 => bool) public claimedNFT;

    // EVENTS
    /// @notice Emitted when ETH is received
    /// @param sender Address that sent ETH
    /// @param amount Amount of ETH received
    event EtherReceived(address indexed sender, uint256 amount);

    /// @notice Emitted when a new rewardProject is launched
    /// @param projectId Unique identifier for the rewardProject
    /// @param projectName Token address of the rewardProject
    event RewardProjectLaunched(uint256 indexed projectId, address indexed projectName);

    /// @notice Emitted when a kol is allocated a TVS amount
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param amount TVS amount
    /// @param vestingPeriod duration of the vesting period
    event TVSAllocated(uint256 indexed projectId, address indexed kol, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when a KOL claims his TVS
    /// @param projectId Unique identifier for the rewardProject
    /// @param kol address of the KOL
    /// @param nftId ID of the claimed nft
    /// @param amount TVS amount
    /// @param vestingPeriod duration of the vesting period
    event RewardTVSClaimed(
        uint256 indexed projectId, address indexed kol, uint256 nftId, uint256 amount, uint256 vestingPeriod
    );

    /// @notice Emitted when a new biddingProject is launched
    /// @param projectId Unique identifier for the biddingProject
    /// @param projectName Token address of the biddingProject
    /// @param stablecoinAddress Stablecoin address of the biddingProject
    /// @param startTime Start time for the biddingProject
    /// @param endTimeHash End time hash for the biddingProject (hidden from end user till biddingProject is closed)
    event BiddingProjectLaunched(
        uint256 indexed projectId,
        address indexed projectName,
        address indexed stablecoinAddress,
        uint256 startTime,
        bytes32 endTimeHash
    );

    /// @notice Emitted when a bid is placed
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param amount Amount of stablecoin committed
    /// @param vestingPeriod Desired vesting duration
    event BidPlaced(uint256 indexed projectId, address indexed user, uint256 amount, uint256 vestingPeriod);

    /// @notice Emitted when a bid is refunded
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param amount Amount of stablecoin refunded
    event BidRefunded(uint256 indexed projectId, address indexed user, uint256 amount);

    /// @notice Emitted when a new vesting pool is created
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool
    /// @param totalAllocation Total tokens allocated to the pool
    /// @param tokenPrice token price set for this pool
    /// @param hasExtraRefund whether pool has extra refund
    event PoolCreated(
        uint256 indexed projectId,
        uint256 indexed poolId,
        uint256 totalAllocation,
        uint256 tokenPrice,
        bool hasExtraRefund
    );

    /// @notice Emitted when a bid is updated
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param oldAmount Previous bid amount
    /// @param newAmount Updated bid amount
    /// @param oldVestingPeriod Previous vesting period
    /// @param newVestingPeriod Updated vesting period
    event BidUpdated(
        uint256 indexed projectId,
        address indexed user,
        uint256 oldAmount,
        uint256 newAmount,
        uint256 oldVestingPeriod,
        uint256 newVestingPeriod
    );

    /// @notice Emitted when bidding is closed and allocations are finalized
    /// @param projectId ID of the biddingProject
    event BiddingClosed(uint256 indexed projectId);

    /// @notice Emitted when an NFT is claimed for an accepted bid
    /// @param projectId ID of the biddingProject
    /// @param user Address of the bidder
    /// @param tokenId ID of the minted NFT
    /// @param poolId ID of the pool allocated to
    /// @param amount Amount allocated
    event NFTClaimed(
        uint256 indexed projectId, address indexed user, uint256 indexed tokenId, uint256 poolId, uint256 amount
    );

    /// @notice Emitted when bidding is closed and merkle roots are set
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool
    /// @param merkleRoot Merkle root for the pool's bid allocations
    event PoolAllocationSet(uint256 indexed projectId, uint256 indexed poolId, bytes32 merkleRoot);

    /// @notice Emitted when bidding is closed and refund merkle root is set
    /// @param projectId ID of the biddingProject
    /// @param refundRoot Merkle root for the project's refund allocations
    event RefundRootSet(uint256 indexed projectId, bytes32 refundRoot);

    /// @notice Emitted when the owner updates the vestingPeriodDivisor
    /// @param oldVestingPeriodDivisor old vestingPeriodDivisor
    /// @param newVestingPeriodDivisor new vestingPeriodDivisor
    event vestingPeriodDivisorUpdated(uint256 oldVestingPeriodDivisor, uint256 newVestingPeriodDivisor);

    /// @notice Emitted when the owner withdraws a profit generated by a project
    /// @param projectId Id of the project to withdraw from
    /// @param amount profit withdrawn from project
    event ProfitWithdrawn(uint256 projectId, uint256 amount);

    /// @notice Emitted when the owner sets the allocations for all the project's pools
    /// @param projectId Id of the project
    /// @param claimDeadline deadline for users to claim their refunds
    event AllPoolAllocationsSet(uint256 projectId, uint256 claimDeadline);

    // ERRORS
    error Zero_Value();
    error Same_Value();
    error Zero_Address();
    error Already_Claimed();
    error Project_Still_Open();
    error Project_Already_Closed();
    error Invalid_Project_Id();
    error Vesting_Period_Is_Not_Multiple_Of_The_Base_Value();
    error New_Vesting_Period_Cannot_Be_Smaller();
    error New_Bid_Cannot_Be_Smaller();
    error No_Bid_Found();
    error Bid_Already_Exists();
    error Merkle_Root_Already_Set();
    error Cannot_Exceed_Ten_Pools_Per_Project();
    error Array_Lengths_Must_Match();
    error Amounts_Do_Not_Add_Up_To_Total_Allocation();
    error Deadline_Has_Passed();
    error Deadline_Has_Not_Passed();
    error Caller_Has_No_TVS_Allocation();
    error Invalid_Merkle_Proof();
    error Invalid_Merkle_Roots_Length();
    error Starttime_Must_Be_Smaller_Than_Endtime();
    error Bidding_Period_Is_Not_Active();
    error User_Is_Not_whitelisted();
    error Transfer_Failed();
    error Insufficient_Balance();
    error Project_Allocation_Is_Not_Set_Yet();

    /// @notice Modifier that prevents non-whitelisted users bidding in a project that has its whitelisting mechanism enabled
    /// @param projectId ID of the project
    modifier checkWhitelist(uint256 projectId) {
        if (isWhitelistEnabled[projectId]) {
            require(isWhitelisted[msg.sender][projectId], User_Is_Not_whitelisted());
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the Alignerz contract
    /// @param _nftContract Address of the NFT contract
    /// @param _TVSManager Address of the TVSManager contract
    function initialize(address _nftContract, address _TVSManager) public initializer {
        __Ownable_init(msg.sender);
        __BiddingFeesManager_init();
        __WhitelistManager_init();
        require(_nftContract != address(0), Zero_Address());
        require(_TVSManager != address(0), Zero_Address());
        nftContract = IAlignerzNFT(_nftContract);
        TVSManager = ITVSManager(_TVSManager);
        vestingPeriodDivisor = 2_592_000; // Set default vesting period multiples to 1 month (2592000 seconds)
    }

    /// @notice Handles direct ETH transfers to the contract
    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }

    /// @notice Handles unknown function calls
    fallback() external payable {
        revert();
    }

    /// @notice Allows owner to withdraw stuck tokens
    /// @param tokenAddress Address of the token to withdraw
    /// @param amount Amount of tokens to withdraw
    function withdrawStuckTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(tokenAddress != address(0), Zero_Address());

        IERC20 token = IERC20(tokenAddress);
        require(token.balanceOf(address(this)) >= amount, Insufficient_Balance());
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Allows owner to withdraw stuck ETH
    /// @param amount Amount of ETH to withdraw
    function withdrawStuckETH(uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(address(this).balance >= amount, Insufficient_Balance());

        (bool success,) = msg.sender.call{value: amount}("");
        require(success, Transfer_Failed());
    }

    /// @notice Changes the vesting period multiples
    /// @dev Only callable by the owner.
    /// @param newVestingPeriodDivisor the new value
    /// @return bool indicating success of the operation.
    function setVestingPeriodDivisor(uint256 newVestingPeriodDivisor) external onlyOwner returns (bool) {
        require(newVestingPeriodDivisor > 0, Zero_Value());
        uint256 oldVestingPeriodDivisor = vestingPeriodDivisor;
        require(newVestingPeriodDivisor != vestingPeriodDivisor, Same_Value());
        vestingPeriodDivisor = newVestingPeriodDivisor;
        emit vestingPeriodDivisorUpdated(oldVestingPeriodDivisor, newVestingPeriodDivisor);
        return true;
    }

    function _setTVS(TVSParams memory p) internal {
        TVSManager.setTVS(
            p.nftId, p.amount, p.vestingPeriod, p.vestingStartTime, p.token, p.projectId, p.isBiddingProject, p.poolId
        );
    }

    // Reward Projects
    /// @notice Launches a new vesting biddingProject
    /// @param tokenAddress Address of the token to be vested by KOLs
    function launchRewardProject(address tokenAddress) external onlyOwner {
        require(tokenAddress != address(0), Zero_Address());

        RewardProject storage rewardProject = rewardProjects[rewardProjectCount];
        rewardProject.startTime = block.timestamp;
        rewardProject.token = IERC20(tokenAddress);

        emit RewardProjectLaunched(rewardProjectCount, tokenAddress);
        rewardProjectCount++;
    }

    /// @notice Sets KOLs TVS allocations
    /// @param rewardProjectId Id of the rewardProject
    /// @param totalTVSAllocation total amount to be allocated in TVSs to KOLs
    /// @param vestingPeriod duration the vesting periods
    /// @param kolTVS addresses of the KOLs who chose to be rewarded in TVS
    /// @param TVSamounts token amounts allocated for the KOLs who chose to be rewarded in TVS
    function setTVSAllocation(
        uint256 rewardProjectId,
        uint256 totalTVSAllocation,
        uint256 vestingPeriod,
        address[] calldata kolTVS,
        uint256[] calldata TVSamounts
    ) external onlyOwner {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        rewardProject.vestingPeriod = vestingPeriod;
        uint256 length = kolTVS.length;
        require(length == TVSamounts.length, Array_Lengths_Must_Match());
        uint256 totalAmount;
        for (uint256 i = 0; i < length; i++) {
            address kol = kolTVS[i];
            rewardProject.kolTVSAddresses.push(kol);
            uint256 amount = TVSamounts[i];
            rewardProject.kolTVSRewards[kol] = amount;
            rewardProject.kolTVSIndexOf[kol] = i;
            totalAmount += amount;
            emit TVSAllocated(rewardProjectId, kol, amount, vestingPeriod);
        }
        require(totalTVSAllocation == totalAmount, Amounts_Do_Not_Add_Up_To_Total_Allocation());
        rewardProject.token.safeTransferFrom(msg.sender, address(this), totalTVSAllocation);
    }

    /// @notice Allows a KOL to claim his TVS
    /// @param rewardProjectId Id of the rewardProject
    function claimRewardTVS(uint256 rewardProjectId) external returns (uint256) {
        RewardProject storage rewardProject = rewardProjects[rewardProjectId];
        address kol = msg.sender;
        uint256 amount = rewardProject.kolTVSRewards[kol];
        require(amount > 0, Caller_Has_No_TVS_Allocation());
        rewardProject.kolTVSRewards[kol] = 0;
        uint256 nftId = nftContract.mint(kol);
        uint256 vestingPeriod = rewardProject.vestingPeriod;
        uint256 vestingStartTime = rewardProject.startTime;
        IERC20 token = rewardProject.token;
        TVSParams memory p;
        p.nftId = nftId;
        p.amount = amount;
        p.vestingPeriod = vestingPeriod;
        p.vestingStartTime = vestingStartTime;
        p.token = token;
        p.projectId = rewardProjectId;
        p.isBiddingProject = false;
        p.poolId = 0;
        _setTVS(p);
        token.safeTransfer(address(TVSManager), amount);
        uint256 index = rewardProject.kolTVSIndexOf[kol];
        uint256 arrayLength = rewardProject.kolTVSAddresses.length;
        address lastIndexAddress = rewardProject.kolTVSAddresses[arrayLength - 1];
        rewardProject.kolTVSIndexOf[lastIndexAddress] = index;
        rewardProject.kolTVSAddresses[index] = rewardProject.kolTVSAddresses[arrayLength - 1];
        rewardProject.kolTVSAddresses.pop();
        emit RewardTVSClaimed(rewardProjectId, kol, nftId, amount, vestingPeriod);
        return nftId;
    }

    // Bidding projects
    /// @notice Launches a new vesting biddingProject
    /// @param tokenAddress Address of the token to be vested
    /// @param stablecoinAddress Address of the token used for bidding
    /// @param startTime Start time of the bidding period
    /// @param endTime End time of the bidding period (this is set to far in the future and reset when biddingProject is closed)
    /// @param endTimeHash End time hash for the biddingProject (hidden from end user till biddingProject is closed)
    /// @param whitelistStatus Whether the biddingProject has enabled his whitelisting mechanism or not
    function launchBiddingProject(
        address tokenAddress,
        address stablecoinAddress,
        uint256 startTime,
        uint256 endTime,
        bytes32 endTimeHash,
        bool whitelistStatus
    ) external onlyOwner {
        require(tokenAddress != address(0), Zero_Address());
        require(stablecoinAddress != address(0), Zero_Address());
        require(startTime < endTime, Starttime_Must_Be_Smaller_Than_Endtime());

        BiddingProject storage biddingProject = biddingProjects[biddingProjectCount];
        biddingProject.token = IERC20(tokenAddress);
        biddingProject.stablecoin = IERC20(stablecoinAddress);
        biddingProject.startTime = startTime;
        biddingProject.endTime = endTime;
        biddingProject.poolCount = 0;
        biddingProject.endTimeHash = endTimeHash;
        isWhitelistEnabled[biddingProjectCount] = whitelistStatus;
        emit BiddingProjectLaunched(biddingProjectCount, tokenAddress, stablecoinAddress, startTime, endTimeHash);
        biddingProjectCount++;
    }

    /// @notice Creates a new vesting pool in a biddingProject
    /// @param projectId ID of the biddingProject
    /// @param totalAllocation Total tokens allocated to this pool
    /// @param tokenPrice token price set for this pool
    function createPool(uint256 projectId, uint256 totalAllocation, uint256 tokenPrice, bool hasExtraRefund)
        external
        onlyOwner
    {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        require(totalAllocation > 0, Zero_Value());
        require(tokenPrice > 0, Zero_Value());

        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(!biddingProject.closed, Project_Already_Closed());
        require(biddingProject.poolCount < 10, Cannot_Exceed_Ten_Pools_Per_Project());

        biddingProject.token.safeTransferFrom(msg.sender, address(this), totalAllocation);

        uint256 poolId = biddingProject.poolCount;
        biddingProject.vestingPools[poolId] = VestingPool({
            merkleRoot: bytes32(0), // Initialize with empty merkle root
            hasExtraRefund: hasExtraRefund
        });

        biddingProject.poolCount++;

        emit PoolCreated(projectId, poolId, totalAllocation, tokenPrice, hasExtraRefund);
    }

    /// @notice Places a bid for token vesting
    /// @param projectId ID of the biddingProject
    /// @param amount Amount of stablecoin to commit
    /// @param vestingPeriod Desired vesting duration
    function placeBid(uint256 projectId, uint256 amount, uint256 vestingPeriod) external checkWhitelist(projectId) {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        require(amount > 0, Zero_Value());

        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(
            block.timestamp >= biddingProject.startTime && block.timestamp <= biddingProject.endTime
                && !biddingProject.closed,
            Bidding_Period_Is_Not_Active()
        );
        require(biddingProject.bids[msg.sender].amount == 0, Bid_Already_Exists());

        require(vestingPeriod > 0, Zero_Value());

        require(
            vestingPeriod < 2 || vestingPeriod % vestingPeriodDivisor == 0,
            Vesting_Period_Is_Not_Multiple_Of_The_Base_Value()
        );

        biddingProject.stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        if (bidFee > 0) {
            biddingProject.stablecoin.safeTransferFrom(msg.sender, TVSManager.treasury(), bidFee);
        }
        biddingProject.bids[msg.sender] = Bid({amount: amount, vestingPeriod: vestingPeriod});
        biddingProject.totalStablecoinBalance += amount;

        emit BidPlaced(projectId, msg.sender, amount, vestingPeriod);
    }

    /// @notice Updates an existing bid
    /// @param projectId ID of the biddingProject
    /// @param newAmount New amount of stablecoin to commit
    /// @param newVestingPeriod New vesting duration
    function updateBid(uint256 projectId, uint256 newAmount, uint256 newVestingPeriod)
        external
        checkWhitelist(projectId)
    {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(
            block.timestamp >= biddingProject.startTime && block.timestamp <= biddingProject.endTime
                && !biddingProject.closed,
            Bidding_Period_Is_Not_Active()
        );

        Bid storage bid = biddingProject.bids[msg.sender];
        uint256 oldAmount = bid.amount;
        require(oldAmount > 0, No_Bid_Found());
        require(newAmount >= oldAmount, New_Bid_Cannot_Be_Smaller());
        require(newVestingPeriod > 0, Zero_Value());
        require(newVestingPeriod >= bid.vestingPeriod, New_Vesting_Period_Cannot_Be_Smaller());
        if (newVestingPeriod > 1) {
            require(newVestingPeriod % vestingPeriodDivisor == 0, Vesting_Period_Is_Not_Multiple_Of_The_Base_Value());
        }

        uint256 oldVestingPeriod = bid.vestingPeriod;

        if (newAmount > oldAmount) {
            uint256 additionalAmount = newAmount - oldAmount;
            biddingProject.totalStablecoinBalance += additionalAmount;
            biddingProject.stablecoin.safeTransferFrom(msg.sender, address(this), additionalAmount);
        }

        if (updateBidFee > 0) {
            biddingProject.stablecoin.safeTransferFrom(msg.sender, TVSManager.treasury(), updateBidFee);
        }
        bid.amount = newAmount;
        bid.vestingPeriod = newVestingPeriod;

        emit BidUpdated(projectId, msg.sender, oldAmount, newAmount, oldVestingPeriod, newVestingPeriod);
    }

    /// @notice Finalizes bids by setting merkle roots for each pool
    /// @param projectId ID of the biddingProject
    function finalizeBids(uint256 projectId) external onlyOwner {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(!biddingProject.closed, Project_Already_Closed());
        biddingProject.closed = true;
        biddingProject.endTime = block.timestamp;
        emit BiddingClosed(projectId);
    }

    /// @notice updates biddingProject merkle trees for each pool
    /// @param projectId ID of the biddingProject
    /// @param refundRoot merkle root for refunds
    /// @param merkleRoots Array of merkle roots, one per pool
    /// @param claimWindow window of time during which users should claim their refunds
    function setProjectAllocations(
        uint256 projectId,
        bytes32 refundRoot,
        bytes32[] calldata merkleRoots,
        uint256 claimWindow
    ) external onlyOwner {
        require(projectId < biddingProjectCount, Invalid_Project_Id());
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(biddingProject.closed, Project_Still_Open());
        require(merkleRoots.length == biddingProject.poolCount, Invalid_Merkle_Roots_Length());

        // Set merkle root for each pool
        for (uint256 poolId = 0; poolId < biddingProject.poolCount; poolId++) {
            biddingProject.vestingPools[poolId].merkleRoot = merkleRoots[poolId];
            emit PoolAllocationSet(projectId, poolId, merkleRoots[poolId]);
        }
        biddingProject.claimDeadline = block.timestamp + claimWindow;
        biddingProject.refundRoot = refundRoot;
        emit RefundRootSet(projectId, refundRoot);
        emit AllPoolAllocationsSet(projectId, biddingProject.claimDeadline);
    }

    /// @notice Allows users to claim refunds for rejected bids
    /// @param projectId ID of the biddingProject
    /// @param amount Amount allocated
    /// @param merkleProof Merkle proof of refund
    function claimRefund(uint256 projectId, uint256 amount, bytes32[] calldata merkleProof) external {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        require(biddingProject.claimDeadline > block.timestamp, Deadline_Has_Passed());

        Bid storage bid = biddingProject.bids[msg.sender];
        require(bid.amount > 0, No_Bid_Found());

        uint256 poolId = 0;
        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, projectId, poolId));
        require(!claimedRefund[leaf], Already_Claimed());
        require(MerkleProof.verify(merkleProof, biddingProject.refundRoot, leaf), Invalid_Merkle_Proof());
        claimedRefund[leaf] = true;

        biddingProject.totalStablecoinBalance -= amount;
        biddingProject.stablecoin.safeTransfer(msg.sender, amount);

        emit BidRefunded(projectId, msg.sender, amount);
    }

    /// @notice Claims an NFT certificate for an accepted bid with merkle proof
    /// @param projectId ID of the biddingProject
    /// @param poolId ID of the pool allocated to
    /// @param amount Amount allocated
    /// @param merkleProof Merkle proof of allocation
    function claimNFT(uint256 projectId, uint256 poolId, uint256 amount, bytes32[] calldata merkleProof)
        external
        returns (uint256)
    {
        BiddingProject storage biddingProject = biddingProjects[projectId];

        Bid storage bid = biddingProject.bids[msg.sender];
        require(bid.amount > 0, No_Bid_Found());

        // Verify merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, projectId, poolId));

        require(!claimedNFT[leaf], Already_Claimed());
        require(
            MerkleProof.verify(merkleProof, biddingProject.vestingPools[poolId].merkleRoot, leaf),
            Invalid_Merkle_Proof()
        );

        claimedNFT[leaf] = true;
        TVSParams memory p;
        p.amount = amount;
        p.projectId = projectId;
        p.isBiddingProject = true;
        p.poolId = poolId;
        p.nftId = nftContract.mint(msg.sender);
        p.vestingPeriod = bid.vestingPeriod;
        p.vestingStartTime = biddingProject.endTime;
        p.token = biddingProject.token;
        _setTVS(p);

        p.token.safeTransfer(address(TVSManager), amount);
        emit NFTClaimed(projectId, msg.sender, p.nftId, poolId, amount);

        return p.nftId;
    }

    /// @notice Allows the owner to withdraw a project's profits
    /// @param projectId ID of the biddingProject
    function withdrawPostDeadlineProfit(uint256 projectId) external onlyOwner {
        BiddingProject storage biddingProject = biddingProjects[projectId];
        uint256 deadline = biddingProject.claimDeadline;
        require(biddingProject.refundRoot != bytes32(0), Project_Allocation_Is_Not_Set_Yet());
        require(block.timestamp > deadline, Deadline_Has_Not_Passed());
        uint256 amount = biddingProject.totalStablecoinBalance;
        biddingProject.stablecoin.safeTransfer(TVSManager.treasury(), amount);
        biddingProject.totalStablecoinBalance = 0;
        emit ProfitWithdrawn(projectId, amount);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
