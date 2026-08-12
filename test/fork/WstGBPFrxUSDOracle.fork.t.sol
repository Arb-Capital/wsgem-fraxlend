// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {WsgemFraxlendDualOracle} from "../../src/WsgemFraxlendDualOracle.sol";
import {IDualOracle} from "../../src/interfaces/IDualOracle.sol";
import {IWsgem} from "../../src/interfaces/IWsgem.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {WstGBPFrxUSDOracleScript, WstGBPFrxUSDConstants} from "../../script/WstGBPFrxUSD.s.sol";
import {WsgemFraxlendConfig} from "../../script/WsgemFraxlendDeploy.s.sol";

/// @dev Replays the pre-write-back state: `ORACLE()` now records the 2026-08-11 deployment and
///      the production oracle script refuses a second one, but this rehearsal exists to re-walk
///      that original deployment path against live state.
contract OracleScriptHarness is WstGBPFrxUSDOracleScript {
    function ORACLE() public pure override(WsgemFraxlendConfig, WstGBPFrxUSDConstants) returns (address) {
        return address(0);
    }
}

/// @notice The oracle deployed against live mainnet state, through the production script path.
/// @dev Exercises the script path used by `make oracle-deploy`, including preflight and
///      post-deployment assertions.
contract WstGBPFrxUSDOracleForkTest is Test {
    // The live addresses, retyped from the instance sheet (docs/instances/wstgbp-frxusd.md).
    address internal constant WSTGBP = 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    address internal constant GBP_USD = 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    address internal constant FRXUSD_USD = 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;

    WsgemFraxlendDualOracle internal oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));
        oracle = (new OracleScriptHarness()).run();
    }

    function test_theProductionScriptPathDeploysAndSelfAsserts() public view {
        // `run()` already walked preflight and every wiring assertion; what remains is that the
        // result stands on its own.
        (bool bad_, uint256 low_, uint256 high_) = oracle.getPrices();
        assertFalse(bad_);
        assertGt(low_, 0);
        assertLe(low_, high_);
    }

    function test_theProductionPreflightRefusesToLaunchOnAStaleFeed() public {
        // Runtime continuity does not justify launching a new oracle while its warning is already
        // active. With no new rounds on the pinned fork, the preflight names the first stale leg
        // before any broadcast begins.
        vm.warp(block.timestamp + 7 days);
        OracleScriptHarness script_ = new OracleScriptHarness();
        vm.expectRevert(bytes("preflight/gem-feed-stale"));
        script_.run();
    }

    function test_theLivePriceSitsInTheExpectedBandAndInsideTheDeviationGate() public view {
        (, uint256 low_, uint256 high_) = oracle.getPrices();

        // Collateral-per-asset: wstGBP above par against a ~$1.35 GBP prices well under 1e18.
        assertGt(low_, 4e17);
        assertLt(high_, 1e18);

        assertLt(1e5 * (high_ - low_) / high_, 5_000);
    }

    function test_thePriceMatchesAnIndependentRecomputationFromTheRawSources() public view {
        uint256 burn_ = IWsgem(WSTGBP).burncost();
        uint256 mint_ = IWsgem(WSTGBP).mintcost();
        (, int256 gbp_,,,) = IChainlinkAggregator(GBP_USD).latestRoundData();
        (, int256 frx_,,,) = IChainlinkAggregator(FRXUSD_USD).latestRoundData();
        assertGt(gbp_, 0);
        assertGt(frx_, 0);

        // Positive by the asserts above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 gbpRaw_ = uint256(gbp_);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 frxRaw_ = uint256(frx_);

        (, uint256 low_, uint256 high_) = oracle.getPrices();
        assertEq(high_, frxRaw_ * 1e36 / (burn_ * gbpRaw_));
        assertEq(low_, frxRaw_ * 1e36 / (mint_ * gbpRaw_));
    }

    function test_theInterfaceIdMatchesTheExpectedFraxLendId() public view {
        bytes4 id_ = type(IDualOracle).interfaceId;
        assertEq(id_, bytes4(0x415f1303));
        assertTrue(oracle.supportsInterface(id_));
    }

    function test_theNormalizedPricesAreTheRawPricesForAnEighteenDecimalCollateral() public view {
        (, uint256 low_, uint256 high_) = oracle.getPrices();
        (, uint256 nLow_, uint256 nHigh_) = oracle.getPricesNormalized();
        assertEq(nLow_, low_);
        assertEq(nHigh_, high_);
    }

    function test_theMetadataReadsAsTheInstanceSheetSays() public view {
        assertEq(oracle.name(), "frxUSD/wstGBP DualOracle");
        assertEq(oracle.QUOTE_TOKEN_0(), WSTGBP);
        assertEq(oracle.BASE_TOKEN_0(), address(840));
        assertEq(oracle.CHAINLINK_FEED_ADDRESS(), GBP_USD);
        assertEq(oracle.PRICE_SCALE(), 1e36);
        assertEq(oracle.decimals(), 18);
    }
}
