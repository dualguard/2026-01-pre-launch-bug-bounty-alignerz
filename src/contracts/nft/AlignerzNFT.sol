// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

///@notice access control
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
/// @notice libraries & utils
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
/// @notice ERC721
import "./ERC721A.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/* 
    @title Alignerz NFT contract
	@notice ERC721-ready Alignerz contract
    Jad Jabbour | Alignerz | Cryptoware ME
*/
contract AlignerzNFT is Ownable, ERC721A, Pausable {
    using Strings for uint256;
    /// This is a Uniform Resource Identifier, distinct used to identify each unique nft from the other.

    string private _baseTokenURI;

    /// @notice the max supply fot SFTs and NFTs, metadata file type
    string private constant _METADATA_EXTENSION = ".json";

    /// @notice mapping that shows whether an address is that of a minter or not
    mapping(address => bool) public minters;

    /// @notice mapping that shows whether an address is that of a pauseGuardian or not
    mapping(address => bool) public pauseGuardians;

    mapping(address => uint256) public nbOfApprovedForAll;

    /// @notice Ensures only the authorized minter can call the function
    modifier onlyMinter() {
        require(minters[msg.sender], "Caller is not a minter");
        _;
    }

    /// @notice Ensures only the authorized pauseGuardian can call the function
    modifier onlyPauseGuardian() {
        require(pauseGuardians[msg.sender], "Caller is not a pauseGuardian");
        _;
    }

    /// @notice Mint event to be emitted upon NFT mint
    event Minted(address indexed to, uint256 indexed tokenId);

    /**
     * @notice constructor
     * @param name_ the token name
     * @param symbol_ the token symbol
     * @param uri_ token metadata URI
     *
     */
    constructor(string memory name_, string memory symbol_, string memory uri_)
        ERC721A(name_, symbol_)
        Ownable(msg.sender)
    {
        _baseTokenURI = uri_;
        minters[msg.sender] = true;
    }

    /// @notice Changes the base URL for token metadata.
    /// @dev Only callable by the owner.
    /// @param newBaseURL The new base URL string.
    /// @return bool indicating success of the operation.
    function changeBaseURL(string memory newBaseURL) public onlyOwner returns (bool) {
        require(bytes(newBaseURL).length > 0, "Base URL cannot be empty");
        require(
            keccak256(bytes(newBaseURL)) != keccak256(bytes(_baseTokenURI)),
            "New base URL must be different from current"
        );
        _baseTokenURI = newBaseURL;
        return true;
    }

    /// @notice Gets the current base URL.
    /// @return The current base URL string.
    function getBaseURL() public view returns (string memory) {
        return _baseTokenURI;
    }

    /// @notice Gets the token URI for a specific token ID.
    /// @param tokenId The token ID.
    /// @return The token URI string.
    function tokenURI(uint256 tokenId) public view override(ERC721A) returns (string memory) {
        return uri(tokenId);
    }

    /// @notice pauses the contract (minting and transfers)
    function pause() external virtual onlyPauseGuardian {
        _pause();
    }

    /// @notice unpauses the contract (minting and transfers)
    function unpause() external virtual onlyPauseGuardian {
        _unpause();
    }

    /**
     * @notice gets the URI per token ID
     * @param tokenId token type ID to return proper URI
     *
     */
    function uri(uint256 tokenId) public view virtual returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();

        return string(abi.encodePacked(_baseTokenURI, tokenId.toString(), _METADATA_EXTENSION));
    }

    /**
     * @notice mints tokens based on parameters
     * @param to address of the user minting
     *
     */
    function mint(address to) external whenNotPaused onlyMinter returns (uint256) {
        require(to != address(0), "Alignerz: Address cannot be 0");

        uint256 startToken = _currentIndex;
        _safeMint(to, 1);

        emit Minted(to, startToken);
        return startToken;
    }

    /**
     * @notice a burn function for burning specific tokenId
     * @param tokenId Id of the Token
     *
     */
    function burn(uint256 tokenId) external whenNotPaused onlyMinter {
        require(_exists(tokenId), "Alignerz: Token Id does not exist");
        _burn(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public virtual override whenNotPaused {
        _transfer(from, to, tokenId);
    }

    /**
     * @dev See {IERC721-safeTransferFrom}.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data)
        public
        virtual
        override
        whenNotPaused
    {
        _transfer(from, to, tokenId);
        if (isContract(to) && !_checkContractOnERC721Received(from, to, tokenId, _data)) {
            revert TransferToNonERC721ReceiverImplementer();
        }
    }

    /**
     * @notice returns true if the NFT has 0 approvals
     * @param tokenId The tokenId of the NFT
     */
    function hasZeroApprovals(uint256 tokenId) public view returns (bool) {
        return (getApproved(tokenId) == address(0)) && (nbOfApprovedForAll[ownerOf(tokenId)] == 0);
    }

    /**
     * @notice Overrides `setApprovalForAll` to update the number of operators approved for all
     * @param operator The address of the operator
     * @param approved The approval status
     */
    function setApprovalForAll(address operator, bool approved) public virtual override {
        if (operator == _msgSender()) revert ApproveToCaller();
        if (approved != isApprovedForAll(_msgSender(), operator)) {
            if (approved) nbOfApprovedForAll[_msgSender()]++;
            else nbOfApprovedForAll[_msgSender()]--;
        }
        _operatorApprovals[_msgSender()][operator] = approved;
        emit ApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @notice Adds a minter
     * @param newMinter The address of the new minter
     */
    function addMinter(address newMinter) external onlyOwner {
        require(newMinter != address(0), "Alignerz: Address cannot be 0");
        require(!minters[newMinter], "Alignerz: Address already a minter");
        minters[newMinter] = true;
    }

    /**
     * @notice Removes a minter
     * @param newMinter The address of the minter to remove
     */
    function removeMinter(address newMinter) external onlyOwner {
        require(newMinter != address(0), "Alignerz: Address cannot be 0");
        require(minters[newMinter], "Alignerz: Address not a minter");
        minters[newMinter] = false;
    }

    /**
     * @notice Adds a pauseGuardian
     * @param pauseGuardian The address of the pauseGuardian to add
     */
    function addPauseGuardian(address pauseGuardian) external onlyOwner {
        require(pauseGuardian != address(0), "Alignerz: Address cannot be 0");
        require(!pauseGuardians[pauseGuardian], "Alignerz: Address already a pauseGuardian");
        pauseGuardians[pauseGuardian] = true;
    }

    /**
     * @notice Removes a pauseGuardian
     * @param pauseGuardian The address of the pauseGuardian to remove
     */
    function removePauseGuardian(address pauseGuardian) external onlyOwner {
        require(pauseGuardian != address(0), "Alignerz: Address cannot be 0");
        require(pauseGuardians[pauseGuardian], "Alignerz: Address not a pauseGuardian");
        pauseGuardians[pauseGuardian] = false;
    }
}
