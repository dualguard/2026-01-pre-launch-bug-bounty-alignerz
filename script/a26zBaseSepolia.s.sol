// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {AlignerzNFT} from "../src/contracts/nft/AlignerzNFT.sol";
import {Alignerz} from "../src/contracts/vesting/Alignerz.sol";
import {TVSManager} from "../src/contracts/vesting/TVSManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TokensDeployer} from "../src/contracts/deploy/TokensDeployer.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract a26zBaseSepolia is Script {
    using Strings for address;

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.rpcUrl("base-sepolia"));

        vm.startBroadcast();
        address owner = 0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9;
        address treasury = 0x64E6728D28D323Dd17b4232857B3A8e3AB9194d9;
        new TokensDeployer().deploy(owner);
        address nft = address(new AlignerzNFT("AlignerzNFT", "AZNFT", "https://api.alignerz-labs.com/nft/"));
        string memory newBaseURL = string.concat("https://api.alignerz-labs.com/84532/", nft.toHexString(), "/nft/");
        AlignerzNFT(nft).changeBaseURL(newBaseURL);
        address tvsImpl = address(new TVSManager());
        address payable tvsManager =
            payable(address(new ERC1967Proxy(tvsImpl, abi.encodeCall(TVSManager.initialize, (nft)))));

        address alignerzImpl = address(new Alignerz());
        address payable alignerz =
            payable(address(new ERC1967Proxy(alignerzImpl, abi.encodeCall(Alignerz.initialize, (nft, tvsManager)))));
        AlignerzNFT(nft).addMinter(tvsManager);
        AlignerzNFT(nft).addMinter(alignerz);

        TVSManager(tvsManager).setTreasury(treasury);
        TVSManager(tvsManager).setAlignerz(alignerz);

        AlignerzNFT(nft).addPauseGuardian(owner);

        // Transfer ownerships
        AlignerzNFT(nft).transferOwnership(owner);
        Alignerz(alignerz).transferOwnership(owner);
        TVSManager(tvsManager).transferOwnership(owner);
        vm.stopBroadcast();
    }
}
