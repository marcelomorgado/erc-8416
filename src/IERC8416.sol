// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

interface IERC8416 {
    event EpochAdded(
        uint256 indexed epochId,
        uint256 rate,
        uint256 maxDeposits,
        uint256 start,
        uint256 entryWindowEnd,
        uint256 accrualStart,
        uint256 accrualEnd,
        uint256 exitWindowStart,
        uint256 end
    );

    event Terminated();

    function epochId() external view returns (uint256 id);

    function rate(uint256 id) external view returns (uint256 rate);

    function maxEpochDeposits(uint256 id) external view returns (uint256 maxAssets);

    function epochPeriod(uint256 id) external view returns (uint256 start, uint256 end);

    function entryWindow(uint256 id) external view returns (uint256 start, uint256 end);

    function accrualInterval(uint256 id) external view returns (uint256 start, uint256 end);

    function exitWindow(uint256 id) external view returns (uint256 start, uint256 end);

    function currentRate() external view returns (uint256 rate);

    function isTerminated() external view returns (bool terminated);
}

interface IERC8416AsyncRedeem is IERC8416 {
    function maxRequestRedeem(address owner) external view returns (uint256 maxShares);
}
