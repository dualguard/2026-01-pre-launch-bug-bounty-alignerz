// SPDX-License-Identifier: MIT
pragma solidity =0.8.29;

import {A26Z} from "../token/A26Z.sol";
import {MockUSD} from "../..//MockUSD.sol";

contract TokensDeployer {
    function deploy(address owner) external returns (address token, address mockUSD) {
        if (block.chainid != 8453) {
            mockUSD = address(new MockUSD());
            MockUSD(mockUSD).transfer(owner, MockUSD(mockUSD).balanceOf(address(this)));
            MockUSD(mockUSD).transferOwnership(owner);
        }
        token = address(new A26Z("A26Z", "A26Z"));
        A26Z(token).transfer(owner, A26Z(token).balanceOf(address(this)));
        A26Z(token).transferOwnership(owner);
    }
}
