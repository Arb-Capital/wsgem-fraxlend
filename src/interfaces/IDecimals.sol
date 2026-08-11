// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IDecimals
/// @notice The one ERC-20 view this repo needs from tokens it never holds.
/// @dev Declared as its own file rather than inline so the oracle and the deploy scripts can
///      assert the same thing about the same token.
interface IDecimals {
    function decimals() external view returns (uint8);
}
