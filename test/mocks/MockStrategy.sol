// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFixedRateStrategy} from "../../src/IFixedRateStrategy.sol";

/// @dev Holds vault funds; must be pre-funded to pay interest. `shortfall` simulates a faulty strategy.
contract MockStrategy is IFixedRateStrategy {
    IERC20 public immutable token;
    uint256 public shortfall;

    constructor(IERC20 token_) {
        token = token_;
    }

    function setShortfall(uint256 shortfall_) external {
        shortfall = shortfall_;
    }

    function allocate(uint256 assets) external {
        token.transferFrom(msg.sender, address(this), assets - shortfall);
    }

    function deallocate(uint256 assets) external {
        token.transfer(msg.sender, assets - shortfall);
    }
}
