// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {IDualOracle, IERC165} from "./interfaces/IDualOracle.sol";
import {IWsgem} from "./interfaces/IWsgem.sol";
import {IPip} from "./interfaces/IPip.sol";
import {IChainlinkAggregator} from "./interfaces/IChainlinkAggregator.sol";
import {IDecimals} from "./interfaces/IDecimals.sol";

/// @title  WsgemFraxlendDualOracle
/// @author Arb Capital
/// @notice Ownerless FraxLend dual oracle for a wsgem collateral against a USD-stable asset.
///         Passes the wsgem's own primary-market quotes straight through: the redemption quote
///         (`burncost()`) values the collateral for borrowing, the issuance quote (`mintcost()`)
///         values it for liquidation, and two Chainlink fiat legs carry both into the asset's
///         terms.
///
///         FraxLend prices are collateral-per-asset: `getPrices()` returns the amount of collateral
///         that 1e18 units of the asset buys. This reverses the usual quote direction. `burncost()`,
///         the lower collateral valuation, becomes `priceHigh` and is used for borrow solvency.
///         `mintcost()` becomes `priceLow` and is used for liquidations.
///
/// @dev    There is no owner, no timelock, no setter and no upgrade path; every parameter is
///         immutable and the contract has no storage. The wsgem NAV is already administered
///         upstream, so this oracle does not add another administrative role. Changing a delay or
///         name requires a new deployment.
///
///         A stale Chainlink leg still has a usable last price, so the oracle
///         returns that price with `isBadData = true`. FraxLend emits `WarnOracleData` and keeps
///         using it. This preserves withdrawals, repayments and liquidations if a feed stops
///         publishing, but also permits new borrowing at the old FX price because the warning is
///         advisory. Inputs from which no valid price can be formed revert
///         (paused pip, zero quote, non-positive or malformed Chainlink answer, upstream revert,
///         zero composed price or arithmetic overflow).
///
///         The pip is read before `burncost()` and `mintcost()`. Those quotes resolve through an
///         upgradeable gate and may remain nonzero while the pip is paused. A zero pip value is
///         therefore checked before either quote is accepted.
///
///         Token-specific values are constructor arguments. For a same-currency market, passing
///         the same Chainlink feed for both legs cancels the FX conversion.
contract WsgemFraxlendDualOracle is IDualOracle {
    // --- Constants ---------------------------------------------------------------------------

    /// @inheritdoc IDualOracle
    /// @dev The asset-side basis of the price: collateral units per 1e18 of asset.
    uint256 public constant ORACLE_PRECISION = 1e18;

    /// @dev ISO 4217 numeric code for USD, Frax's convention for "the dollar" as a base token.
    address internal constant _USD = address(840);

    /// @dev Constructor bounds for feed staleness windows.
    uint256 internal constant _MIN_DELAY = 1 hours;
    uint256 internal constant _MAX_DELAY = 7 days;

    /// @dev Keeps every exponent term in [0, 18] and the folded exponent in [0, 72].
    uint8 internal constant _MAX_DECIMALS = 18;

    // --- Immutables: the price machine -------------------------------------------------------

    /// @notice The wsgem this oracle prices, i.e. the pair's collateral token. Always 18 decimals.
    IWsgem public immutable WSGEM;

    /// @notice The wsgem's price feed, cached at construction. The pause authority.
    IPip public immutable PIP;

    /// @notice The gem the wsgem's quotes are denominated in, cached at construction.
    address public immutable GEM;

    /// @notice The pair's asset token (the USD stable being lent).
    address public immutable ASSET;

    /// @notice Chainlink leg one: USD per unit of the GEM's currency (e.g. GBP/USD).
    IChainlinkAggregator public immutable GEM_USD_FEED;

    /// @notice Staleness bound for `GEM_USD_FEED`, seconds. Frax convention: heartbeat + 300.
    uint256 public immutable GEM_USD_MAX_DELAY;

    /// @notice Chainlink leg two: USD per unit of the ASSET (e.g. a stablecoin's USD feed).
    IChainlinkAggregator public immutable ASSET_USD_FEED;

    /// @notice Staleness bound for `ASSET_USD_FEED`, seconds.
    uint256 public immutable ASSET_USD_MAX_DELAY;

    /// @notice Decimals of `WSGEM.burncost()`/`mintcost()` -- i.e. the GEM's decimals.
    /// @dev Supplied by the constructor because the pip's writable decimals value is not tied to
    ///      its published scale. The deployment preflight checks this against `GEM.decimals()`.
    uint8 public immutable QUOTE_DECIMALS;

    /// @notice The folded power of ten: `price = assetRaw * PRICE_SCALE / (quoteRaw * gemRaw)`.
    /// @dev Derivation. With P_a = USD per asset token and P_c = USD per wsgem, FraxLend wants
    ///      `1e18 * (P_a / P_c) * 10^(collateralDec - assetDec)` with collateralDec pinned to 18.
    ///      Substituting P_a = assetRaw / 10^assetFeedDec and
    ///      P_c = quoteRaw * gemRaw / 10^(quoteDec + gemFeedDec) and folding every power of ten:
    ///
    ///          PRICE_SCALE = 10^(36 - assetDec - assetFeedDec + quoteDec + gemFeedDec)
    ///
    ///      1e36 for an 18-decimal asset with two 8-decimal feeds and an 18-decimal gem. The
    ///      exponent is non-negative for every input the constructor admits (see _MAX_DECIMALS),
    ///      so one multiplier covers every configuration.
    uint256 public immutable PRICE_SCALE;

    // --- Immutables: IDualOracle metadata ----------------------------------------------------

    /// @dev Frax convention: both "routes" of a dual oracle get a base/quote pair. This oracle has
    ///      a single price machine feeding both the low and high leg, so the two pairs are
    ///      identical: USD (the ISO sentinel, at an assumed 18 decimals) against the collateral.
    address public immutable BASE_TOKEN_0;
    uint256 public immutable BASE_TOKEN_0_DECIMALS;
    address public immutable BASE_TOKEN_1;
    uint256 public immutable BASE_TOKEN_1_DECIMALS;
    address public immutable QUOTE_TOKEN_0;
    uint256 public immutable QUOTE_TOKEN_0_DECIMALS;
    address public immutable QUOTE_TOKEN_1;
    uint256 public immutable QUOTE_TOKEN_1_DECIMALS;

    /// @dev Quote decimals minus base decimals, per Frax's `DualOracleBase`. The wsgem is asserted
    ///      18-decimal and the USD sentinel is assumed 18, so this is always zero here and
    ///      `getPricesNormalized()` is always the identity.
    int256 public immutable NORMALIZATION_0;
    int256 public immutable NORMALIZATION_1;

    /// @notice The fiat leg a UI would chart, exposed under the name Frax tooling looks for.
    /// @dev A contract-level extra, NOT an `IDualOracle` member: the interface id the live
    ///      reference oracle registers (0x415f1303) excludes this selector, verified on-chain.
    address public immutable CHAINLINK_FEED_ADDRESS;

    /// @dev The oracle's name, packed. Immutable, so a rename means a new deployment.
    bytes32 internal immutable _NAME;

    // --- Errors ------------------------------------------------------------------------------

    error ZeroAddress();
    error UnsupportedDecimals();
    error DelayOutOfBounds();
    error NameTooLong();
    error OraclePaused();
    error InvalidQuote();
    error InvalidFeedAnswer();
    error InvalidPrice();

    // --- Construction ------------------------------------------------------------------------

    /// @param wsgem_            The wsgem to price; the pair's collateral. Must be 18 decimals.
    /// @param asset_            The pair's asset token. Decimals read live, must be <= 18.
    /// @param gemUsdFeed_       Chainlink USD feed for the gem's currency.
    /// @param gemUsdMaxDelay_   Staleness bound for `gemUsdFeed_`, in [1 hours, 7 days].
    /// @param assetUsdFeed_     Chainlink USD feed for the asset.
    /// @param assetUsdMaxDelay_ Staleness bound for `assetUsdFeed_`, in [1 hours, 7 days].
    /// @param quoteDecimals_    Decimals of `wsgem_.burncost()`, i.e. the gem's decimals, <= 18.
    /// @param name_             Oracle name, at most 32 bytes. Immutable.
    constructor(
        IWsgem wsgem_,
        address asset_,
        IChainlinkAggregator gemUsdFeed_,
        uint256 gemUsdMaxDelay_,
        IChainlinkAggregator assetUsdFeed_,
        uint256 assetUsdMaxDelay_,
        uint8 quoteDecimals_,
        string memory name_
    ) {
        if (address(wsgem_) == address(0)) revert ZeroAddress();
        if (asset_ == address(0)) revert ZeroAddress();
        if (address(gemUsdFeed_) == address(0)) revert ZeroAddress();
        if (address(assetUsdFeed_) == address(0)) revert ZeroAddress();
        if (bytes(name_).length > 32) revert NameTooLong();

        if (gemUsdMaxDelay_ < _MIN_DELAY || gemUsdMaxDelay_ > _MAX_DELAY) revert DelayOutOfBounds();
        if (assetUsdMaxDelay_ < _MIN_DELAY || assetUsdMaxDelay_ > _MAX_DELAY) revert DelayOutOfBounds();

        address gem_ = wsgem_.gem();
        address pip_ = wsgem_.pip();
        if (gem_ == address(0) || pip_ == address(0)) revert ZeroAddress();

        // The scaling formula assumes an 18-decimal collateral.
        if (wsgem_.decimals() != 18) revert UnsupportedDecimals();
        if (quoteDecimals_ > _MAX_DECIMALS) revert UnsupportedDecimals();

        uint8 assetDec_ = IDecimals(asset_).decimals();
        uint8 gemFeedDec_ = gemUsdFeed_.decimals();
        uint8 assetFeedDec_ = assetUsdFeed_.decimals();
        if (assetDec_ > _MAX_DECIMALS) revert UnsupportedDecimals();
        if (gemFeedDec_ > _MAX_DECIMALS) revert UnsupportedDecimals();
        if (assetFeedDec_ > _MAX_DECIMALS) revert UnsupportedDecimals();

        // Every term is bounded to [0, 18] above, so the exponent sits in [0, 72] and the
        // subtraction cannot underflow: 36 + quoteDec + gemFeedDec >= 36 >= assetDec + assetFeedDec.
        uint256 scale_ =
            10 ** (36 + uint256(quoteDecimals_) + uint256(gemFeedDec_) - uint256(assetDec_) - uint256(assetFeedDec_));

        WSGEM = wsgem_;
        PIP = IPip(pip_);
        GEM = gem_;
        ASSET = asset_;
        GEM_USD_FEED = gemUsdFeed_;
        GEM_USD_MAX_DELAY = gemUsdMaxDelay_;
        ASSET_USD_FEED = assetUsdFeed_;
        ASSET_USD_MAX_DELAY = assetUsdMaxDelay_;
        QUOTE_DECIMALS = quoteDecimals_;
        PRICE_SCALE = scale_;

        BASE_TOKEN_0 = _USD;
        BASE_TOKEN_0_DECIMALS = 18;
        BASE_TOKEN_1 = _USD;
        BASE_TOKEN_1_DECIMALS = 18;
        QUOTE_TOKEN_0 = address(wsgem_);
        QUOTE_TOKEN_0_DECIMALS = 18;
        QUOTE_TOKEN_1 = address(wsgem_);
        QUOTE_TOKEN_1_DECIMALS = 18;
        NORMALIZATION_0 = 0;
        NORMALIZATION_1 = 0;
        CHAINLINK_FEED_ADDRESS = address(gemUsdFeed_);

        // Length-checked to <= 32 above, so no character is dropped; a shorter string is
        // right-padded with zero bytes, which `_b32ToString` treats as padding rather than content.
        // forge-lint: disable-next-line(unsafe-typecast)
        _NAME = bytes32(bytes(name_));

        // Exercise the complete price path during construction. Parameters are passed directly
        // because immutables cannot be read reliably until construction completes.
        _compose(IPip(pip_), wsgem_, gemUsdFeed_, gemUsdMaxDelay_, assetUsdFeed_, assetUsdMaxDelay_, scale_);
    }

    // --- IDualOracle: prices -----------------------------------------------------------------

    /// @inheritdoc IDualOracle
    /// @dev The only function the pair calls. A stale but otherwise valid Chainlink answer is
    ///      served with `isBadData = true`; data from which no valid price can be formed reverts.
    function getPrices() public view returns (bool isBadData, uint256 priceLow, uint256 priceHigh) {
        return _compose(PIP, WSGEM, GEM_USD_FEED, GEM_USD_MAX_DELAY, ASSET_USD_FEED, ASSET_USD_MAX_DELAY, PRICE_SCALE);
    }

    /// @inheritdoc IDualOracle
    /// @dev The identity here: the price is already at 18 decimals because the collateral is
    ///      (NORMALIZATION is zero). Present because Frax tooling reads it.
    function getPricesNormalized() external view returns (bool isBadData, uint256 priceLow, uint256 priceHigh) {
        return getPrices();
    }

    // --- IDualOracle: metadata ---------------------------------------------------------------

    /// @inheritdoc IDualOracle
    /// @dev The COLLATERAL's decimals, which is what `getPrices()` is served at. Fixed 18.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @inheritdoc IDualOracle
    function name() external view returns (string memory) {
        return _b32ToString(_NAME);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId_) external pure returns (bool) {
        return interfaceId_ == type(IDualOracle).interfaceId || interfaceId_ == type(IERC165).interfaceId;
    }

    // --- Internals ---------------------------------------------------------------------------

    /// @dev Shared by the constructor self-check and `getPrices()`. Parameters allow the
    ///      constructor to call it before the immutables are readable.
    ///
    ///      The pip must be read before the wsgem quotes because it is the pause authority. The
    ///      result is sorted because the two spreads are configured independently upstream, while
    ///      FraxLend expects `priceLow <= priceHigh`.
    function _compose(
        IPip pip_,
        IWsgem wsgem_,
        IChainlinkAggregator gemFeed_,
        uint256 gemDelay_,
        IChainlinkAggregator assetFeed_,
        uint256 assetDelay_,
        uint256 scale_
    ) internal view returns (bool isBadData_, uint256 priceLow_, uint256 priceHigh_) {
        if (pip_.read() == 0) revert OraclePaused();

        uint256 burn_ = wsgem_.burncost();
        uint256 mint_ = wsgem_.mintcost();
        if (burn_ == 0 || mint_ == 0) revert InvalidQuote();

        (uint256 gemRaw_, bool gemIsStale_) = _readFeed(gemFeed_, gemDelay_);
        (uint256 assetRaw_, bool assetIsStale_) = _readFeed(assetFeed_, assetDelay_);
        isBadData_ = gemIsStale_ || assetIsStale_;

        // The lower collateral valuation from burncost buys more collateral per unit of asset,
        // so it maps to priceHigh. Both divisions round down.
        priceHigh_ = assetRaw_ * scale_ / (burn_ * gemRaw_);
        priceLow_ = assetRaw_ * scale_ / (mint_ * gemRaw_);

        if (priceLow_ > priceHigh_) (priceLow_, priceHigh_) = (priceHigh_, priceLow_);
        // A zero exchange rate reads as infinitely valuable collateral to the pair's LTV math.
        if (priceLow_ == 0) revert InvalidPrice();
    }

    /// @dev Returns a positive, timestamped answer and whether it exceeds the freshness bound.
    ///      Future timestamps are invalid.
    function _readFeed(IChainlinkAggregator feed_, uint256 maxDelay_)
        internal
        view
        returns (uint256 raw_, bool isStale_)
    {
        (, int256 answer_,, uint256 updatedAt_,) = feed_.latestRoundData();

        if (answer_ <= 0) revert InvalidFeedAnswer();
        if (updatedAt_ == 0) revert InvalidFeedAnswer();
        // forge-lint: disable-next-line(block-timestamp)
        if (updatedAt_ > block.timestamp) revert InvalidFeedAnswer();
        // forge-lint: disable-next-line(block-timestamp)
        isStale_ = block.timestamp - updatedAt_ > maxDelay_;

        // Positive by the first check above.
        // forge-lint: disable-next-line(unsafe-typecast)
        raw_ = uint256(answer_);
    }

    /// @dev Trailing zero bytes are the padding of a short name, not content.
    function _b32ToString(bytes32 b32_) internal pure returns (string memory) {
        uint256 len_;
        while (len_ < 32 && b32_[len_] != 0) len_++;

        bytes memory out_ = new bytes(len_);
        for (uint256 i_; i_ < len_; i_++) {
            out_[i_] = b32_[i_];
        }

        return string(out_);
    }
}
