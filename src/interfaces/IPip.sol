// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IPip
/// @notice The wsgem's oracle price feed.
/// @dev `read()` returns a stored value published by an authorized account. There is no
///      `updatedAt` view, so consumers cannot check its age on-chain.
///
///      A paused feed reads zero. This oracle reverts on zero because FraxLend treats
///      `isBadData` as advisory and would otherwise use the returned price.
interface IPip {
    /// @notice The raw NAV in gem-per-wsgem at the gem's decimals. Zero when paused.
    function read() external view returns (uint256);
}
