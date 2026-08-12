// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A Chainlink push feed that can be driven into the states the oracle must handle.
/// @dev The signed answer permits tests for zero and negative feed values. `REVERTING` exercises
///      upstream call failure handling.
contract MockChainlinkFeed {
    enum Mode {
        NORMAL,
        REVERTING
    }

    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimals;
    Mode public mode;

    constructor(int256 answer_, uint8 decimals_) {
        answer = answer_;
        decimals = decimals_;
        updatedAt = block.timestamp;
    }

    /// @notice Publish a round now.
    function set(int256 answer_) external {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    /// @notice Publish a round with an arbitrary timestamp.
    function setAt(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == Mode.REVERTING) revert("feed: unreadable");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
