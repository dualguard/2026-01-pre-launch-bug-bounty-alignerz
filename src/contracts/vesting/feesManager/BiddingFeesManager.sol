// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

abstract contract BiddingFeesManager is OwnableUpgradeable {
    /// @notice Fee that a user pays when placing a bid
    uint256 public bidFee;

    /// @notice Fee that a user pays when updating a bid
    uint256 public updateBidFee;

    /// @notice Emitted when the owner updates the bidFee
    /// @param oldBidFee old bidFee
    /// @param newBidFee new bidFee
    event bidFeeUpdated(uint256 oldBidFee, uint256 newBidFee);

    /// @notice Emitted when the owner updates the updateBidFee
    /// @param oldUpdateBidFee old updateBidFee
    /// @param newUpdateBidFee new updateBidFee
    event updateBidFeeUpdated(uint256 oldUpdateBidFee, uint256 newUpdateBidFee);

    function __BiddingFeesManager_init() internal onlyInitializing {}

    /// @notice Sets multiple fee parameters in a single transaction.
    /// @dev Calls internal setters for bid and bid update.
    /// @param _bidFee The new bid fee value to set.
    /// @param _bidUpdateFee The new bid update fee value to set.
    function setBiddingFees(uint256 _bidFee, uint256 _bidUpdateFee) public onlyOwner {
        _setBidFee(_bidFee);
        _setUpdateBidFee(_bidUpdateFee);
    }

    /*
     * @notice Updates the bid fee.
     * @param bidFee The new bid fee value.
     * @dev Restricted to contract owner.
     *
     * Emits a {bidFeeUpdated} event.
     */
    function setBidFee(uint256 _bidFee) public onlyOwner {
        _setBidFee(_bidFee);
    }

    /**
     * @notice Internal function to update the bid fee.
     * @param newBidFee The new bid fee value.
     *
     * Emits a {bidFeeUpdated} event.
     *
     * Requirements:
     * - `newBidFee` must satisfy internal minimum and maximum constraints.
     */
    function _setBidFee(uint256 newBidFee) internal {
        // Example placeholder limits
        require(newBidFee < 1_000_001, "Bid fee too high");

        uint256 oldBidFee = bidFee;
        bidFee = newBidFee;

        emit bidFeeUpdated(oldBidFee, newBidFee);
    }

    /**
     * @notice Updates the bid update fee.
     * @param _updateBidFee The new bid update fee value.
     *
     * Emits an {updateBidFeeUpdated} event.
     */
    function setUpdateBidFee(uint256 _updateBidFee) public onlyOwner {
        _setUpdateBidFee(_updateBidFee);
    }

    /**
     * @notice Internal function to update the bid update fee.
     * @param newUpdateBidFee The new bid update fee value.
     *
     * Emits an {updateBidFeeUpdated} event.
     */
    function _setUpdateBidFee(uint256 newUpdateBidFee) internal {
        require(newUpdateBidFee < 1_000_001, "Bid update fee too high");

        uint256 oldUpdateBidFee = updateBidFee;
        updateBidFee = newUpdateBidFee;

        emit updateBidFeeUpdated(oldUpdateBidFee, newUpdateBidFee);
    }

    uint256[50] private __gap;
}
