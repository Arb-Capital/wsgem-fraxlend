// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IWsgem
/// @notice The subset of a wrapped-staked gem (wsgem) that a FraxLend dual oracle needs.
/// @dev A wsgem is a non-rebasing ERC-20 wrapper over an underlying `gem`. The wrapper sets `gem`
///      and `pip` in its constructor, so the oracle caches both addresses at construction.
///
///      `mintcost()` is the issuance quote and `burncost()` is the redemption quote. Adjustable
///      spreads place them above and below NAV.
interface IWsgem {
    /// @notice The underlying purchase token the wsgem is priced in.
    function gem() external view returns (address);

    /// @notice The oracle price feed. Immutable on the wrapper.
    function pip() external view returns (address);

    /// @notice The raw NAV in gem-per-wsgem at the gem's decimals, un-fee-adjusted. Equals
    ///         `IPip(pip()).read()`.
    /// @dev Zero means the feed is paused.
    function navprice() external view returns (uint256);

    /// @notice The redemption quote in gem-per-wsgem: what one wsgem actually redeems for, i.e.
    ///         the NAV net of the wrapper's redemption spread.
    /// @dev Zero when the feed is paused, like `navprice()` -- and also whenever the redemption
    ///      spread is set to 100%, so a zero here means "unusable", not merely "paused". The
    ///      spread is adjustable on the wrapper (no getter is exposed for it), so consumers should
    ///      read this quote live rather than reconstructing it from `navprice()` and a cached fee.
    function burncost() external view returns (uint256);

    /// @notice The issuance quote in gem-per-wsgem: what minting one wsgem costs, i.e. the NAV
    ///         plus the wrapper's issuance spread.
    /// @dev Zero when the feed is paused. Always >= `navprice()` >= `burncost()` while the spreads
    ///      are sane, but nothing on the wrapper enforces that ordering for consumers -- the
    ///      spreads are independently settable -- so a dual oracle sorts rather than assumes.
    function mintcost() external view returns (uint256);

    /// @notice ERC-20 decimals. The oracle requires 18.
    function decimals() external view returns (uint8);
}
