// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract MergeSplitFeesManager is OwnableUpgradeable {
    /// @notice Fee percentage in basis point that a user pays when splitting a TVS
    uint256 public splitFeeRate;

    /// @notice Fee percentage in basis point that a user pays when merging TVSs
    uint256 public mergeFeeRate;

    /// @notice BasisPoint
    uint256 public constant BASIS_POINT = 10_000;

    /// @notice Emitted when the owner updates the splitFee
    /// @param oldSplitFee old splitFee
    /// @param newSplitFee new splitFee
    event splitFeeRateUpdated(uint256 oldSplitFee, uint256 newSplitFee);

    /// @notice Emitted when the owner updates the mergeFee
    /// @param oldMergeFee old mergeFee
    /// @param newMergeFee new mergeFee
    event mergeFeeRateUpdated(uint256 oldMergeFee, uint256 newMergeFee);

    function __MergeSplitFeesManager_init() internal onlyInitializing {
        _setSplitFeeRate(50);
    }

    /// @notice Sets multiple fee parameters in a single transaction.
    /// @dev Calls internal setters for split and merge fees.
    /// @param _splitFeeRate The new split fee value to set.
    /// @param _mergeFeeRate The new merge fee value to set.
    function setMergeSplitFeeRates(uint256 _splitFeeRate, uint256 _mergeFeeRate) public onlyOwner {
        _setSplitFeeRate(_splitFeeRate);
        _setMergeFeeRate(_mergeFeeRate);
    }

    /**
     * @notice Updates the split fee.
     * @param _splitFee The new split fee value.
     *
     * Emits a {splitFeeRateUpdated} event.
     */
    function setSplitFeeRate(uint256 _splitFee) public onlyOwner {
        _setSplitFeeRate(_splitFee);
    }

    /**
     * @notice Internal function to update the split fee.
     * @param newSplitFeeRate The new split fee value.
     *
     * Emits a {splitFeeRateUpdated} event.
     */
    function _setSplitFeeRate(uint256 newSplitFeeRate) internal {
        require(newSplitFeeRate < 201, "Split fee too high");

        uint256 oldSplitFeeRate = splitFeeRate;
        splitFeeRate = newSplitFeeRate;

        emit splitFeeRateUpdated(oldSplitFeeRate, newSplitFeeRate);
    }

    /**
     * @notice Updates the merge fee.
     * @param _mergeFeeRate The new merge fee value.
     *
     * Emits a {mergeFeeRateUpdated} event.
     */
    function setMergeFeeRate(uint256 _mergeFeeRate) public onlyOwner {
        _setMergeFeeRate(_mergeFeeRate);
    }

    /**
     * @notice Internal function to update the merge fee.
     * @param newMergeFeeRate The new merge fee value.
     *
     * Emits a {mergeFeeRateUpdated} event.
     */
    function _setMergeFeeRate(uint256 newMergeFeeRate) internal {
        require(newMergeFeeRate < 201, "Merge fee too high");

        uint256 oldMergeFeeRate = mergeFeeRate;
        mergeFeeRate = newMergeFeeRate;

        emit mergeFeeRateUpdated(oldMergeFeeRate, newMergeFeeRate);
    }

    uint256[50] private __gap;
}
