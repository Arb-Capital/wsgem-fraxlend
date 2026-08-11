// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

/// @title IWsgem
/// @notice The subset of a wrapped-staked gem (wsgem) that a FraxLend dual oracle needs.
/// @dev A wsgem is an ERC-20 wrapper whose value accrues against an underlying `gem`. It does not
///      rebase: the balance is fixed and the NAV rises. `gem` and `pip` are `immutable` on the
///      wrapper -- set once in its constructor and never repointable -- so an oracle may read them
///      once at construction and cache them.
///
///      The two quotes below are the wrapper's own primary market: `mintcost()` is what issuing
///      one wsgem costs, `burncost()` is what redeeming one pays. They bracket the NAV from above
///      and below by the wrapper's (adjustable) spreads, which is exactly the band a dual oracle
///      wants: no third party can buy below `burncost` or sell above `mintcost` while the primary
///      market is open, so any sustained secondary-market price outside the band is an arbitrage,
///      not a price.
interface IWsgem {
    /// @notice The underlying purchase token the wsgem is priced in.
    function gem() external view returns (address);

    /// @notice The oracle price feed. Immutable on the wrapper.
    function pip() external view returns (address);

    /// @notice The raw NAV in gem-per-wsgem at the gem's decimals, un-fee-adjusted. Equals
    ///         `IPip(pip()).read()`.
    /// @dev Zero means the feed is paused. Callers MUST handle that; it is not an error state the
    ///      wsgem itself signals.
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

    /// @notice ERC-20 decimals. Constant 18 on every wsgem to date; the oracle asserts it anyway.
    function decimals() external view returns (uint8);
}
