// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

interface IFixedRateStrategy {
    function allocate(uint256 assets) external;

    function deallocate(uint256 assets) external;
}
