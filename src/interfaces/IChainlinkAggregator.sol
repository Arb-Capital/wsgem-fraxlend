// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IChainlinkAggregator
/// @notice The subset of Chainlink's `AggregatorV3Interface` this oracle needs: the latest answer,
///         when it was written, and the scale it is written in.
/// @dev Consumers read an `EACAggregatorProxy`, which Chainlink may repoint during a phase change.
///      `decimals()` remains fixed for the life of the feed.
///
///      Unlike a wsgem pip, this feed includes a publication time. `answeredInRound` is not used
///      for OCR feeds, and `startedAt` is the round start rather than the answer timestamp.
///
///      The configured fiat feeds use 8 decimals and a 24-hour heartbeat. Their deviation
///      threshold triggers publication; it does not bound the size of a price move.
interface IChainlinkAggregator {
    /// @notice The latest round. This oracle uses `answer` and `updatedAt`.
    /// @dev `answer` is signed and may be zero or negative.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice The number of decimals `answer` is scaled by. Fixed for the life of the feed.
    function decimals() external view returns (uint8);
}
