# 2026-01-pre-launch-bug-bounty-alignerz
- Join [Dualguard](https://discord.gg/AARXkjn5) Discord
- Submit findings using this public repo (label issues as Low, Medium or High)
- for more details, read the pinned messages inside the github channel: 💂🏻・guards

# Rewards by severity
- High: $3K
- Medium: $1k
- Low: $500

# Q&A
### Q: On what chains are the smart contracts going to be deployed?
Base

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of weird tokens you want to integrate?
Protocol only supports standard tokens with 18 decimals, no weird tokens, no rebase tokens, no fee-on-transfer tokens. There are only 2 stablecoins that will be used for bidding and real yield distribution (USDT and USDC) which have 6 decimals

### Q: Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?
Admin is fully trusted
Minters are trusted(Alignerz and TVSManager contracts)
Array of KOLs will be capped at 1000
`bidFee` and `updateBidFee` can have a maximum of 1 USDC/USDT

`mergeFeeRate` and `splitFeeRate` can be set to 2% at most

### Q: Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?
No

### Q: Is the codebase expected to comply with any specific EIPs?
No

### Q: Are there any off-chain mechanisms involved in the protocol (e.g., keeper bots, arbitrage bots, etc.)? We assume these mechanisms will not misbehave, delay, or go offline unless otherwise specified.
There's a backend that generates the merkleproofs for refunds, TVS allocations in bidding projects. It will also calculate the real yields for the TVS holders

### Q: What properties/invariants do you want to hold even if breaking them has a low/unknown impact?
- At any point in time, for a certain token A: A.balanceOf(address(TVSManager)) >= sum(getAllocationOf(tokenId).amounts - getAllocationOf(tokenId).claimedAmounts) for tokenIds of TVSs issued from bidding or reward projects for that token A, even if these tokenIds result from a split or a merge.
- For a certain token flow: claimedAmount <= amount

### Q: Please discuss any design choices you made.
- I decided to keep the assignedPoolId attribute in the rewardProject struct even if it has no use case, it will always be equal to 0 and that was made for practicality.
- setVestingPeriodDivisor will be rarely called and it will never be called during a bidding
- setAlignerz will only be called inside the deployment script
- it’s the users job to setApprovedForAll to false for all operators and to set getApproved() to address(0) for the tokenId
- refunds are project relative, TVS are pool relative
- extra refunds will be handled off-chain
- The blacklsiting will only be used in case a user was added by mistake, users will not be blacklisted mid-bidding because of misbehaviour, there should be no way for them to misbehave
  
### Q: Please provide links to previous audits (if any) and all the known issues or acceptable risks.
[ShawarmaSec Audit](https://github.com/shawarma-sec/audits/blob/main/final-report-shawarmasec-alignerz.pdf)

Known issues: [Lightchaser](https://gist.github.com/ChaseTheLight01/05252ba91bb7aac661e1ffe30c76f2d5)

- Dust amounts are acceptable as long as they do not break the contract
- It's acceptable to have many users pull together to place one giant bid, bypassing the bidding fees
- It's acceptable to have one user being allocated the total token allocation reserved for a pool
- It's acceptable to have huge vesting periods even though it means some tokens might not be claimable by the user in his lifetime
- Code/doc discrepencies are out of scope for this audit

### Q: Please list any relevant protocol resources.
[Whitepaper](https://drive.google.com/file/d/1xN5bYUPd_BkBMtoRruHEO1CBUx0vBiit/)

### Q: Extra audit information
- Merge will not be included for this launch but it will be included in a future upgrade
- realYieldDistributor will not be deployed now, that’s why it wasn’t included in the script
- The a26zBase.s.sol script should be deployment ready for mainnet

# Scope
All the files inside:
```
contracts-main/script/
contracts-main/src/
```
except
```
contracts-main/src/contracts/realYieldDistributor/RealYieldDistributor.sol
```
