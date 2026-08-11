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
/// @dev The pair itself calls ONLY `getPrices()`; everything else exists for Frax's tooling, UI
///      and risk monitoring. The member set below is exactly the one the live reference oracle
///      registers under ERC-165: `type(IDualOracle).interfaceId == 0x415f1303`, which the fork
///      suite pins against the deployed reference at
///      `0xd84cCBd42046AA35c7d408A92872F0253aEDF030` (the KRWQ reference pair's oracle). Note that
///      Frax's interface FILE also declares `CHAINLINK_FEED_ADDRESS()`, but the id their contracts
///      actually register excludes it -- verified on-chain -- so it is a contract-level extra
///      here, not an interface member.
///
///      PRICE DIRECTION, the one thing that must never be got wrong: `getPrices()` returns the
///      amount of COLLATERAL token, at the collateral's native decimals, that 1e18 (wei) of the
///      ASSET token buys. `FraxlendPairCore` calls it "the amount of collateral to buy 1e18
///      asset". For an 18-decimal collateral worth more than a dollar against a dollar asset the
///      number is BELOW 1e18. Base/quote metadata follows Frax's convention: the base is the ISO
///      4217 sentinel `address(840)` (USD) at an assumed 18 decimals, the quote is the collateral
///      ERC-20.
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
    ///      so an implementation must never return a garbage price alongside `true`.
    function getPrices() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh);

    /// @notice `getPrices()` rescaled to 1e18 regardless of the collateral's decimals.
    function getPricesNormalized() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh);
}
