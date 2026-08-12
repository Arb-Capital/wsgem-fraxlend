// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IERC165
/// @notice Standard interface detection, declared locally so nothing is vendored.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title IDualOracle
/// @notice The oracle interface a FraxLend pair prices against, re-typed from the verified source
///         of the live oracles Frax deploys today.
/// @dev The pair calls `getPrices()`; the remaining functions support Frax tooling, UI
///      and risk monitoring. The member set below has the expected ERC-165 id
///      `type(IDualOracle).interfaceId == 0x415f1303`, pinned by the test suite. Frax's published
///      interface also declares `CHAINLINK_FEED_ADDRESS()`, but that getter is excluded from the
///      registered interface id, so it is not a member here.
///
///      `getPrices()` returns the amount of collateral, at its native decimals, that 1e18 units of
///      the asset buys. For an 18-decimal collateral worth more than a dollar against a dollar
///      asset, the result is below 1e18. Metadata uses `address(840)` for USD as the base and the
///      collateral ERC-20 as the quote.
interface IDualOracle is IERC165 {
    function ORACLE_PRECISION() external view returns (uint256);
    function BASE_TOKEN_0() external view returns (address);
    function BASE_TOKEN_0_DECIMALS() external view returns (uint256);
    function BASE_TOKEN_1() external view returns (address);
    function BASE_TOKEN_1_DECIMALS() external view returns (uint256);
    function QUOTE_TOKEN_0() external view returns (address);
    function QUOTE_TOKEN_0_DECIMALS() external view returns (uint256);
    function QUOTE_TOKEN_1() external view returns (address);
    function QUOTE_TOKEN_1_DECIMALS() external view returns (uint256);
    function NORMALIZATION_0() external view returns (int256);
    function NORMALIZATION_1() external view returns (int256);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);

    /// @notice The two prices the pair reads: `priceLow <= priceHigh`, both collateral-per-asset.
    /// @dev The pair enforces borrow solvency against `priceHigh` (collateral valued cheap) and
    ///      triggers/sizes liquidations against `priceLow` (collateral valued dear). `isBadData`
    ///      is advisory only -- the pair emits a warning event and uses the prices regardless --
    ///      so `true` must only accompany a usable price.
    function getPrices() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh);

    /// @notice `getPrices()` rescaled to 1e18 regardless of the collateral's decimals.
    function getPricesNormalized() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh);
}
