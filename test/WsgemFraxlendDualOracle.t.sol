// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test}                    from "forge-std/Test.sol";
import {WsgemFraxlendDualOracle} from "../src/WsgemFraxlendDualOracle.sol";
import {IDualOracle, IERC165}    from "../src/interfaces/IDualOracle.sol";
import {IWsgem}                  from "../src/interfaces/IWsgem.sol";
import {IChainlinkAggregator}    from "../src/interfaces/IChainlinkAggregator.sol";
import {MockPip, MockToken, MockWsgem} from "./mocks/MockWsgem.sol";
import {MockChainlinkFeed}             from "./mocks/MockChainlinkFeed.sol";

/// @notice The dual oracle over mocked feeds.
/// @dev The worked fixture runs at the exact magnitudes the live wstGBP/frxUSD deployment will
///      see, hand-derived once and pinned as integers -- if the fold in `PRICE_SCALE` or the
///      division order ever changes, these tests break with the wrong number, not merely a wrong
///      bit. Direction (burncost -> HIGH) is proven separately from magnitude, because the two
///      failure shapes -- inverted mapping and mis-scaled fold -- have very different blast radii
///      and deserve to fail loudly on their own.
contract WsgemFraxlendDualOracleTest is Test {
    // The live wstGBP/frxUSD magnitudes, as read from mainnet, and the hand-derived expectations.
    uint256 internal constant NAV0  = 1007380025597183628;  // 18-dp gem per wsgem
    uint256 internal constant BURN0 = 1004861575533190669;  // NAV net of a 25 bp exit spread
    uint256 internal constant MINT0 = 1007380025597183628;  // zero issuance spread on the live wsgem
    int256  internal constant GBP0  = 135133000;            // 8-dp Chainlink GBP/USD
    int256  internal constant FRX0  = 100005313;            // 8-dp Chainlink frxUSD/USD
    uint256 internal constant GBPU  = 135133000;            // the same two, unsigned, for expected-
    uint256 internal constant FRXU  = 100005313;            // value arithmetic without casts

    // price = assetRaw * 1e36 / (quote * gemRaw), floor -- derived by hand from the constants
    // above. 7.36e17 collateral per 1e18 asset, i.e. wstGBP ~= $1.3579.
    uint256 internal constant HIGH0 = 736470601548539699;   // through BURN0
    uint256 internal constant LOW0  = 734629425044668350;   // through MINT0

    uint256 internal constant DELAY = 86700;                // heartbeat + 300, both legs

    MockPip           internal pip;
    MockToken         internal gem;
    MockToken         internal asset;
    MockWsgem         internal wsgem;
    MockChainlinkFeed internal gemFeed;
    MockChainlinkFeed internal assetFeed;

    WsgemFraxlendDualOracle internal oracle;

    function setUp() public {
        vm.warp(1_800_000_000);
        pip       = new MockPip(NAV0);
        gem       = new MockToken(18);
        asset     = new MockToken(18);
        wsgem     = new MockWsgem(address(gem), address(pip), 18);
        gemFeed   = new MockChainlinkFeed(GBP0, 8);
        assetFeed = new MockChainlinkFeed(FRX0, 8);
        wsgem.setQuotes(NAV0, BURN0, MINT0);
        oracle    = _deploy();
    }

    function _deploy() internal returns (WsgemFraxlendDualOracle) {
        return new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)),
            address(asset),
            IChainlinkAggregator(address(gemFeed)),
            DELAY,
            IChainlinkAggregator(address(assetFeed)),
            DELAY,
            18,
            "wsgem/stable DualOracle"
        );
    }

    // --- Construction: wiring ------------------------------------------------------------------

    function test_constructionWiresEveryImmutable() public view {
        assertEq(address(oracle.WSGEM()),          address(wsgem));
        assertEq(address(oracle.PIP()),            address(pip));
        assertEq(oracle.GEM(),                     address(gem));
        assertEq(oracle.ASSET(),                   address(asset));
        assertEq(address(oracle.GEM_USD_FEED()),   address(gemFeed));
        assertEq(oracle.GEM_USD_MAX_DELAY(),       DELAY);
        assertEq(address(oracle.ASSET_USD_FEED()), address(assetFeed));
        assertEq(oracle.ASSET_USD_MAX_DELAY(),     DELAY);
        assertEq(oracle.QUOTE_DECIMALS(),          18);
        assertEq(oracle.ORACLE_PRECISION(),        1e18);
    }

    function test_theFoldedScaleIsExactlyOneE36ForTheAllStandardDecimals() public view {
        // 10^(36 - assetDec(18) - assetFeedDec(8) + quoteDec(18) + gemFeedDec(8)) = 10^36.
        assertEq(oracle.PRICE_SCALE(), 1e36);
    }

    function test_theMetadataFollowsTheFraxConvention() public view {
        assertEq(oracle.BASE_TOKEN_0(),           address(840));
        assertEq(oracle.BASE_TOKEN_0_DECIMALS(),  18);
        assertEq(oracle.BASE_TOKEN_1(),           address(840));
        assertEq(oracle.BASE_TOKEN_1_DECIMALS(),  18);
        assertEq(oracle.QUOTE_TOKEN_0(),          address(wsgem));
        assertEq(oracle.QUOTE_TOKEN_0_DECIMALS(), 18);
        assertEq(oracle.QUOTE_TOKEN_1(),          address(wsgem));
        assertEq(oracle.QUOTE_TOKEN_1_DECIMALS(), 18);
        assertEq(oracle.NORMALIZATION_0(),        int256(0));
        assertEq(oracle.NORMALIZATION_1(),        int256(0));
        assertEq(oracle.CHAINLINK_FEED_ADDRESS(), address(gemFeed));
        assertEq(oracle.decimals(),               18);
        assertEq(oracle.name(),                   "wsgem/stable DualOracle");
    }

    // --- Construction: guards ------------------------------------------------------------------

    function test_constructionRejectsEveryZeroAddress() public {
        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(0)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(0), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(0)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(0)), DELAY, 18, "x"
        );

        MockWsgem gemless_ = new MockWsgem(address(0), address(pip), 18);
        gemless_.setQuotes(NAV0, BURN0, MINT0);
        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(gemless_)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        MockWsgem pipless_ = new MockWsgem(address(gem), address(0), 18);
        pipless_.setQuotes(NAV0, BURN0, MINT0);
        vm.expectRevert(WsgemFraxlendDualOracle.ZeroAddress.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(pipless_)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );
    }

    function test_constructionRejectsANonEighteenDecimalWsgem() public {
        wsgem.setDecimals(6);
        vm.expectRevert(WsgemFraxlendDualOracle.UnsupportedDecimals.selector);
        _deploy();
    }

    function test_constructionRejectsOversizedDecimalsOnEveryLeg() public {
        vm.expectRevert(WsgemFraxlendDualOracle.UnsupportedDecimals.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 19, "x"
        );

        MockToken wide_ = new MockToken(19);
        vm.expectRevert(WsgemFraxlendDualOracle.UnsupportedDecimals.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(wide_), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        MockChainlinkFeed wideGemFeed_ = new MockChainlinkFeed(GBP0, 19);
        vm.expectRevert(WsgemFraxlendDualOracle.UnsupportedDecimals.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(wideGemFeed_)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        MockChainlinkFeed wideAssetFeed_ = new MockChainlinkFeed(FRX0, 19);
        vm.expectRevert(WsgemFraxlendDualOracle.UnsupportedDecimals.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(wideAssetFeed_)), DELAY, 18, "x"
        );
    }

    function test_constructionRejectsDelaysOutsideTheRails() public {
        vm.expectRevert(WsgemFraxlendDualOracle.DelayOutOfBounds.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), 1 hours - 1,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "x"
        );

        vm.expectRevert(WsgemFraxlendDualOracle.DelayOutOfBounds.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), 7 days + 1, 18, "x"
        );
    }

    function test_constructionAcceptsExactlyThirtyTwoBytesOfNameAndNotThirtyThree() public {
        WsgemFraxlendDualOracle ok_ = new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "abcdefghijklmnopqrstuvwxyz123456"
        );
        assertEq(ok_.name(), "abcdefghijklmnopqrstuvwxyz123456");

        vm.expectRevert(WsgemFraxlendDualOracle.NameTooLong.selector);
        new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 18, "abcdefghijklmnopqrstuvwxyz1234567"
        );
    }

    function test_constructionSelfChecksTheFullReadPath() public {
        pip.poke(0);
        vm.expectRevert(WsgemFraxlendDualOracle.OraclePaused.selector);
        _deploy();
        pip.poke(NAV0);

        wsgem.setQuotes(NAV0, 0, MINT0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidQuote.selector);
        _deploy();
        wsgem.setQuotes(NAV0, BURN0, MINT0);

        gemFeed.set(0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidFeedAnswer.selector);
        _deploy();
        gemFeed.set(GBP0);

        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(WsgemFraxlendDualOracle.StaleFeed.selector);
        _deploy();
        gemFeed.set(GBP0);
        assetFeed.set(FRX0);

        assertEq(address(_deploy()) == address(0), false);
    }

    // --- Prices: the worked fixture ------------------------------------------------------------

    function test_theWorkedWstGBPFrxUSDNumbersReproduceTheHandDerivation() public view {
        (bool bad_, uint256 low_, uint256 high_) = oracle.getPrices();
        assertFalse(bad_);
        assertEq(high_, HIGH0);
        assertEq(low_,  LOW0);
    }

    function test_burncostMapsToPriceHighAndMintcostToPriceLow() public {
        // A wide, unambiguous spread so the mapping cannot pass by accident of magnitude.
        uint256 burn_ = 0.90e18;
        uint256 mint_ = 1.10e18;
        wsgem.setQuotes(NAV0, burn_, mint_);

        (, uint256 low_, uint256 high_) = oracle.getPrices();
        assertEq(high_, FRXU * 1e36 / (burn_ * GBPU));
        assertEq(low_,  FRXU * 1e36 / (mint_ * GBPU));
        assertGt(high_, low_);
    }

    function test_aFlippedSpreadStillComesBackSorted() public {
        // The two spreads are independently settable upstream, so mint < burn is reachable. The
        // pair's deviation gate assumes low <= high; the oracle sorts rather than trusts.
        wsgem.setQuotes(NAV0, 1.10e18, 0.90e18);

        (, uint256 low_, uint256 high_) = oracle.getPrices();
        assertLe(low_, high_);
        assertEq(high_, FRXU * 1e36 / (0.90e18 * GBPU));
    }

    function test_aSameCurrencyMarketCancelsTheFxLegExactly() public {
        // One feed on both legs: the currency conversion must vanish from the composed price,
        // leaving the pure collateral-per-asset inversion of the wsgem quote.
        WsgemFraxlendDualOracle same_ = new WsgemFraxlendDualOracle(
            IWsgem(address(wsgem)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(gemFeed)), DELAY, 18, "wsgem/gem DualOracle"
        );

        (, uint256 low_, uint256 high_) = same_.getPrices();
        assertEq(high_, 1e36 / BURN0);
        assertEq(low_,  1e36 / MINT0);
    }

    function test_theLiveSpreadSitsFarInsideAFivePercentDeviationGate() public view {
        // The gate as FraxlendPairCore computes it: DEVIATION_PRECISION * (high - low) / high.
        (, uint256 low_, uint256 high_) = oracle.getPrices();
        uint256 deviation_ = 1e5 * (high_ - low_) / high_;
        assertEq(deviation_, 249); // ~25 bp, from the wrapper's exit spread
        assertLt(deviation_, 5000);
    }

    function test_getPricesNormalizedIsTheIdentityHere() public view {
        (bool bad_, uint256 low_, uint256 high_)   = oracle.getPrices();
        (bool nBad_, uint256 nLow_, uint256 nHigh_) = oracle.getPricesNormalized();
        assertEq(nLow_,  low_);
        assertEq(nHigh_, high_);
        assertEq(nBad_,  bad_);
    }

    // --- Prices: staleness ---------------------------------------------------------------------
    //
    // Staleness REVERTS rather than flags: both legs share the same fiat feeds, so a frozen feed
    // moves low and high together and the pair's deviation gate -- the only thing `isBadData`
    // could have alerted -- never widens. See the contract's failure-policy note.

    function test_isBadDataIsConstitutionallyFalse() public view {
        (bool bad_,,) = oracle.getPrices();
        assertFalse(bad_);
    }

    function test_theStalenessBoundaryIsExactlyMaxDelay() public {
        uint256 t0_ = block.timestamp;

        vm.warp(t0_ + DELAY);
        (bool bad_, uint256 low_,) = oracle.getPrices();
        assertFalse(bad_);
        assertEq(low_, LOW0);

        vm.warp(t0_ + DELAY + 1);
        vm.expectRevert(WsgemFraxlendDualOracle.StaleFeed.selector);
        oracle.getPrices();
    }

    function test_aStaleGemLegAloneFreezes() public {
        vm.warp(block.timestamp + DELAY + 1);
        assetFeed.set(FRX0); // refresh only the asset leg

        vm.expectRevert(WsgemFraxlendDualOracle.StaleFeed.selector);
        oracle.getPrices();
    }

    function test_aStaleAssetLegAloneFreezes() public {
        vm.warp(block.timestamp + DELAY + 1);
        gemFeed.set(GBP0); // refresh only the gem leg

        vm.expectRevert(WsgemFraxlendDualOracle.StaleFeed.selector);
        oracle.getPrices();
    }

    // --- Prices: the revert taxonomy -----------------------------------------------------------

    function test_aPausedPipFreezesEvenWhenTheGateStillQuotes() public {
        // The hostile-gate state: the pip says paused, the quotes keep answering. Only the pip is
        // the pause authority, and it is read first.
        pip.poke(0);

        vm.expectRevert(WsgemFraxlendDualOracle.OraclePaused.selector);
        oracle.getPrices();
    }

    function test_aZeroBurncostFreezes() public {
        wsgem.setQuotes(NAV0, 0, MINT0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidQuote.selector);
        oracle.getPrices();
    }

    function test_aZeroMintcostFreezes() public {
        wsgem.setQuotes(NAV0, BURN0, 0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidQuote.selector);
        oracle.getPrices();
    }

    function test_aNonPositiveAnswerOnEitherLegFreezes() public {
        gemFeed.set(0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidFeedAnswer.selector);
        oracle.getPrices();
        gemFeed.set(GBP0);

        assetFeed.set(-1);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidFeedAnswer.selector);
        oracle.getPrices();
    }

    function test_aZeroUpdatedAtFreezes() public {
        gemFeed.setAt(GBP0, 0);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidFeedAnswer.selector);
        oracle.getPrices();
    }

    function test_aFutureStampedRoundIsMalformedNotFresh() public {
        assetFeed.setAt(FRX0, block.timestamp + 1);
        vm.expectRevert(WsgemFraxlendDualOracle.InvalidFeedAnswer.selector);
        oracle.getPrices();
    }

    function test_aCollapsedCompositionFreezesRatherThanServingZero() public {
        // A quote and an FX leg large enough that the floor lands on zero: the oracle refuses,
        // because a zero exchange rate reads as infinitely valuable collateral to the LTV math.
        wsgem.setQuotes(NAV0, 1e30, 1e30);
        gemFeed.set(1e16);

        vm.expectRevert(WsgemFraxlendDualOracle.InvalidPrice.selector);
        oracle.getPrices();
    }

    function test_aRevertingPipPropagates() public {
        pip.setMode(MockPip.Mode.REVERTING);
        vm.expectRevert("pip: unreadable");
        oracle.getPrices();
    }

    function test_aRevertingGatePropagates() public {
        wsgem.setMode(MockWsgem.Mode.REVERTING);
        vm.expectRevert("wsgem: unreadable");
        oracle.getPrices();
    }

    function test_aRevertingFeedPropagates() public {
        assetFeed.setMode(MockChainlinkFeed.Mode.REVERTING);
        vm.expectRevert("feed: unreadable");
        oracle.getPrices();
    }

    // --- ERC-165 -------------------------------------------------------------------------------

    function test_theInterfaceIdIsTheOneTheLiveReferenceOracleRegisters() public pure {
        // 0x415f1303 was read off the deployed frxUSD/KRWQ oracle's supportsInterface on mainnet;
        // the fork suite re-checks against the live contract. If this pin breaks, the local
        // IDualOracle declaration has drifted from what Frax's tooling probes for.
        assertEq(type(IDualOracle).interfaceId, bytes4(0x415f1303));
    }

    function test_supportsInterfaceAnswersForBothIdsAndRefusesTheInvalidOne() public view {
        assertTrue(oracle.supportsInterface(type(IDualOracle).interfaceId));
        assertTrue(oracle.supportsInterface(type(IERC165).interfaceId));
        assertFalse(oracle.supportsInterface(0xffffffff));
    }

    // --- Fuzz ----------------------------------------------------------------------------------

    /// @dev The fold, proven decimal-by-decimal: PRICE_SCALE must equal the hand formula for every
    ///      decimals combination the constructor admits.
    function testFuzz_theFoldedScaleMatchesTheDecimalsFormula(
        uint8 quoteDec_,
        uint8 gemFeedDec_,
        uint8 assetDec_,
        uint8 assetFeedDec_
    ) public {
        quoteDec_     = uint8(bound(quoteDec_, 0, 18));
        gemFeedDec_   = uint8(bound(gemFeedDec_, 0, 18));
        assetDec_     = uint8(bound(assetDec_, 0, 18));
        assetFeedDec_ = uint8(bound(assetFeedDec_, 0, 18));

        // Unit-scale values at each leg's claimed decimals, so the constructor's live self-check
        // sees a coherent configuration (a mismatched magnitude is exactly what it exists to
        // refuse, and is not what this test is about).
        MockWsgem fWsgem_ = new MockWsgem(address(gem), address(pip), 18);
        fWsgem_.setQuotes(NAV0, 10 ** uint256(quoteDec_), 10 ** uint256(quoteDec_));
        MockToken fAsset_          = new MockToken(assetDec_);
        MockChainlinkFeed fGem_    = new MockChainlinkFeed(int256(10 ** uint256(gemFeedDec_)), gemFeedDec_);
        MockChainlinkFeed fAssetF_ = new MockChainlinkFeed(int256(10 ** uint256(assetFeedDec_)), assetFeedDec_);

        WsgemFraxlendDualOracle o_ = new WsgemFraxlendDualOracle(
            IWsgem(address(fWsgem_)), address(fAsset_), IChainlinkAggregator(address(fGem_)), DELAY,
            IChainlinkAggregator(address(fAssetF_)), DELAY, quoteDec_, "x"
        );

        uint256 expected_ = 10
            ** (36 + uint256(quoteDec_) + uint256(gemFeedDec_)
                   - uint256(assetDec_) - uint256(assetFeedDec_));
        assertEq(o_.PRICE_SCALE(), expected_);
    }

    /// @dev The defining property of the floor division, checked from outside the contract:
    ///      price * denominator <= numerator < (price + 1) * denominator.
    function testFuzz_theFloorDivisionBoundHolds(uint256 burn_, uint256 mint_, uint256 gem_, uint256 frx_)
        public
    {
        burn_ = bound(burn_, 0.01e18, 1e24);
        mint_ = bound(mint_, burn_, 1e24);
        gem_  = bound(gem_, 1e6, 1e12);   // 8-dp fiat feed, $0.01 to $10,000
        frx_  = bound(frx_, 1e6, 1e12);

        wsgem.setQuotes(NAV0, burn_, mint_);
        // Bounded to [1e6, 1e12] above, far below int256's sign bit.
        // forge-lint: disable-next-line(unsafe-typecast)
        gemFeed.set(int256(gem_));
        // forge-lint: disable-next-line(unsafe-typecast)
        assetFeed.set(int256(frx_));

        (, uint256 low_, uint256 high_) = oracle.getPrices();

        uint256 num_  = frx_ * 1e36;
        uint256 hDen_ = burn_ * gem_;
        uint256 lDen_ = mint_ * gem_;
        assertLe(high_ * hDen_, num_);
        assertGt((high_ + 1) * hDen_, num_);
        assertLe(low_ * lDen_, num_);
        assertGt((low_ + 1) * lDen_, num_);
    }

    /// @dev The same economics expressed at a 6-decimal quote scale must price identically to the
    ///      18-decimal expression -- the fold is a rescaling, never a repricing.
    function testFuzz_quoteDecimalRescalingIsExact(uint256 quoteWad_) public {
        quoteWad_ = bound(quoteWad_, 0.01e18, 1e24);
        // Truncate to what a 6-decimal gem can express, so both oracles see the same number.
        quoteWad_ = quoteWad_ / 1e12 * 1e12;

        wsgem.setQuotes(NAV0, quoteWad_, quoteWad_);
        (, uint256 low18_, uint256 high18_) = oracle.getPrices();

        MockWsgem sixWsgem_ = new MockWsgem(address(gem), address(pip), 18);
        sixWsgem_.setQuotes(NAV0, quoteWad_ / 1e12, quoteWad_ / 1e12);
        WsgemFraxlendDualOracle six_ = new WsgemFraxlendDualOracle(
            IWsgem(address(sixWsgem_)), address(asset), IChainlinkAggregator(address(gemFeed)), DELAY,
            IChainlinkAggregator(address(assetFeed)), DELAY, 6, "x"
        );
        (, uint256 low6_, uint256 high6_) = six_.getPrices();

        assertEq(high6_, high18_);
        assertEq(low6_,  low18_);
    }

    /// @dev Whatever the two quotes do, the pair the oracle returns is sorted and nonzero.
    function testFuzz_anArbitraryQuotePairComesBackSortedAndPositive(uint256 a_, uint256 b_) public {
        a_ = bound(a_, 1, 1e27);
        b_ = bound(b_, 1, 1e27);

        wsgem.setQuotes(NAV0, a_, b_);
        (, uint256 low_, uint256 high_) = oracle.getPrices();

        assertLe(low_, high_);
        assertGt(low_, 0);
    }
}
