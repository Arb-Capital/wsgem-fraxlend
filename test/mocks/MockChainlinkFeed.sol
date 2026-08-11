// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice A Chainlink push feed that can be driven into the states the oracle must handle.
/// @dev `answer` is `int256` on the real interface and CAN be zero or negative on a broken feed,
///      so it is signed here too -- a mock that could only hold positive answers would make the
///      oracle's sign check untestable. As with `MockPip`, one REVERTING mode stands in for every
///      broken-implementation shape, because this oracle's policy is to propagate the revert.
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

    /// @notice Publish a round stamped at an arbitrary time -- how staleness (and a future stamp)
    ///         is driven.
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
