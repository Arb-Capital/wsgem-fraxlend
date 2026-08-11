// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IPip
/// @notice The wsgem's oracle price feed.
/// @dev `read()` is a single stored value published by a permissioned poker. There is no
///      `updatedAt` view -- the publication time exists only in the feed's own event -- so no
///      consumer can bound the age of a price on-chain. Any staleness policy has to be built from
///      what a consumer itself observes, not from the feed.
///
///      A paused feed reads zero. That is the one value this oracle must never propagate: a
///      FraxLend pair treats its oracle's `isBadData` as a warning, not a stop, so the only way
///      to refuse a paused feed is to revert -- which freezes the pair (no borrows, no
///      liquidations) until the feed returns. See the design argument in
///      `WsgemFraxlendDualOracle`.
interface IPip {
    /// @notice The raw NAV in gem-per-wsgem at the gem's decimals. Zero when paused.
    function read() external view returns (uint256);
}
