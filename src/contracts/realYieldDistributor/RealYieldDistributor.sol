// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {ITVSManager} from "../../interfaces/ITVSManager.sol";
import {IAlignerzNFT} from "../../interfaces/IAlignerzNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract RealYieldDistributor is Ownable {
    using SafeERC20 for IERC20;

    // TYPE DEF
    /// @notice Real yield struct
    struct RealYield {
        uint256 amount; // amount in USD in 1e6
        uint256 claimedAmount; // seconds claimed
    }

    /// @notice Real yield distribution struct
    struct RealYieldDistribution {
        uint256 startTime; // Start time of the vesting period
        uint256 vestingPeriod; // length of the vesting period (usually 3 months)
        uint256 totalUnclaimedAmounts; // total value yet to be claimed by TVS holders
        uint256 stablecoinAmountToDistribute; // total stablecoin amount reserved for TVS holders as real yields
        mapping(address => RealYield) realYieldsOf; // user => RealYield
        IERC20 stablecoin; // stablecoin to be distributed
        IERC20 token; // token inside the TVS
        bytes32 merkleRoot; // merkle root
    }

    // STATE VARIABLES
    /// @notice nft interface
    IAlignerzNFT public nft;

    /// @notice tracks unclaimed amounts of a TVS
    mapping(uint256 => RealYieldDistribution) public realYieldDistributions;

    /// @notice tracks whether owner has set real yield allocations
    mapping(uint256 => bool) public realYieldsHaveBeenSet;

    /// @notice tracks whether a user has set his real yield allocation so he can start claiming
    mapping(bytes32 => bool) public realYieldHasBeenSet;

    /// @notice number of distributions
    uint256 public distributionCount;

    // EVENTS
    event distributionLaunched(
        uint256 distributionId,
        address token,
        address stablecoin,
        uint256 startTime,
        uint256 vestingPeriod,
        uint256 stablecoinAmountToDistribute
    );
    event realYieldsSet(uint256 distributionId);
    event realYieldSet(uint256 distributionId, address TVSHolder);
    event realYieldsClaimed(address user, uint256 amountClaimed);

    // ERRORS
    error Zero_Address();
    error Zero_Value();
    error Distribution_Does_Not_Exist();
    error RealYields_Are_Already_Set();
    error RealYield_Is_Already_Set();
    error Invalid_Merkle_Proof();

    /// @notice Initializes the RealYieldDistributor contract
    /// @param _nft Address of the NFT contract
    constructor(address _nft) Ownable(msg.sender) {
        require(_nft != address(0), Zero_Address());
        nft = IAlignerzNFT(_nft);
    }

    /// @notice Allows owner to withdraw stuck tokens
    /// @param tokenAddress Address of the token to withdraw (usdc or usdt)
    /// @param amount Amount of tokens to withdraw
    function withdrawStuckTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(amount > 0, Zero_Value());
        require(tokenAddress != address(0), Zero_Address());

        IERC20 tokenStuck = IERC20(tokenAddress);
        tokenStuck.safeTransfer(msg.sender, amount);
    }

    /// @notice allows the owner to launch a real yield distribution
    /// @param _token Address of the TVS' token
    /// @param _stablecoin Address of the stablecoin
    /// @param _vestingPeriod vesting period for the TVS holders beneficiating from this real yield distribution
    /// @param _stablecoinAmountToDistribute amount allocated for this real yield distribution
    function launchDistribution(
        address _token,
        address _stablecoin,
        uint256 _vestingPeriod,
        uint256 _stablecoinAmountToDistribute
    ) external onlyOwner {
        nft.pause();
        require(_token != address(0), Zero_Address());
        require(_stablecoin != address(0), Zero_Address());
        realYieldDistributions[distributionCount].stablecoin = IERC20(_stablecoin);
        realYieldDistributions[distributionCount].startTime = block.timestamp;
        realYieldDistributions[distributionCount].vestingPeriod = _vestingPeriod;
        realYieldDistributions[distributionCount].token = IERC20(_token);
        realYieldDistributions[distributionCount].stablecoinAmountToDistribute = _stablecoinAmountToDistribute;
        IERC20(_stablecoin).safeTransferFrom(msg.sender, address(this), _stablecoinAmountToDistribute);
        emit distributionLaunched(
            distributionCount, _token, _stablecoin, block.timestamp, _vestingPeriod, _stablecoinAmountToDistribute
        );
        distributionCount++;
    }

    /// @notice allows the owner to set the real yield allocations of the TVS holders
    /// @param distributionId id of the distribution
    /// @param merkleRoot merkle root for allocations
    function setUpTheRealYields(uint256 distributionId, bytes32 merkleRoot) external onlyOwner {
        require(distributionId < distributionCount, Distribution_Does_Not_Exist());
        require(!realYieldsHaveBeenSet[distributionId], RealYields_Are_Already_Set());
        realYieldsHaveBeenSet[distributionId] = true;
        realYieldDistributions[distributionId].merkleRoot = merkleRoot;
        emit realYieldsSet(distributionId);
        nft.unpause();
    }

    /// @notice allows the TVS holder to set his real yields
    /// @param distributionId id of the distribution
    /// @param amount amount
    /// @param merkleProof merkle proof of real yield
    function setUpUserRealYields(uint256 distributionId, uint256 amount, bytes32[] calldata merkleProof) external {
        require(distributionId < distributionCount, Distribution_Does_Not_Exist());
        address TVSHolder = msg.sender;
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount, distributionId));

        require(!realYieldHasBeenSet[leaf], RealYield_Is_Already_Set());
        require(
            MerkleProof.verify(merkleProof, realYieldDistributions[distributionId].merkleRoot, leaf),
            Invalid_Merkle_Proof()
        );

        realYieldHasBeenSet[leaf] = true;
        realYieldDistributions[distributionId].realYieldsOf[TVSHolder].amount = amount;
        emit realYieldSet(distributionId, TVSHolder);
    }

    /// @notice Allows a TVS holder to claim his real yields
    /// @param distributionId id of the distribution
    function claimRealYields(uint256 distributionId) external {
        address user = msg.sender;
        uint256 totalAmount = realYieldDistributions[distributionId].realYieldsOf[user].amount;
        uint256 claimedAmount = realYieldDistributions[distributionId].realYieldsOf[user].claimedAmount;
        uint256 vestingPeriod = realYieldDistributions[distributionId].vestingPeriod;
        uint256 startTime = realYieldDistributions[distributionId].startTime;
        uint256 secondsPassed;
        if (block.timestamp >= vestingPeriod + startTime) {
            secondsPassed = vestingPeriod;
            realYieldDistributions[distributionId].realYieldsOf[user].amount = 0;
        } else {
            secondsPassed = block.timestamp - startTime;
        }
        uint256 claimableAmount = totalAmount * secondsPassed / vestingPeriod - claimedAmount;
        realYieldDistributions[distributionId].realYieldsOf[user].claimedAmount += claimableAmount;
        realYieldDistributions[distributionId].stablecoin.safeTransfer(user, claimableAmount);
        emit realYieldsClaimed(user, claimableAmount);
    }
}
