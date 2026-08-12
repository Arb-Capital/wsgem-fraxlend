// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {WsgemFraxlendDualOracle} from "../../src/WsgemFraxlendDualOracle.sol";
import {IWsgem} from "../../src/interfaces/IWsgem.sol";
import {IChainlinkAggregator} from "../../src/interfaces/IChainlinkAggregator.sol";
import {IFraxlendPair, IFraxlendPairDeployer, IERC20Minimal} from "../../src/interfaces/IFraxlend.sol";
import {WstGBPFrxUSDMarketScript} from "../../script/WstGBPFrxUSD.s.sol";
import {WstGBPFrxUSDConstants} from "../../script/WstGBPFrxUSD.s.sol";
import {WsgemFraxlendConfig} from "../../script/WsgemFraxlendDeploy.s.sol";

/// @dev The wsgem's compliance layer, declared here because only this rehearsal touches it: the
///      token consults `Cop(cop).pass(usr)` on every transfer party -- a default-allow banlist
///      administered on tGBP.
interface IGatedToken {
    function cop() external view returns (address);
}

interface ICop {
    function pass(address usr) external view returns (bool);
}

/// @dev The pair's own errors this rehearsal expects, retyped from the live pair's verified ABI.
interface IFraxlendPairErrors {
    error Insolvent(uint256 borrow, uint256 collateral, uint256 exchangeRate);
    error ExceedsMaxOracleDeviation();
    error BorrowerSolvent();
}

/// @dev Backs the one non-`pure` instance getter with storage, so the market script's own
///      preflight, encoder and post-deploy assertions run against an oracle that exists only
///      inside this fork.
contract MarketScriptHarness is WstGBPFrxUSDMarketScript {
    address internal _oracle;

    function setOracle(address oracle_) external {
        _oracle = oracle_;
    }

    function ORACLE() public view override(WsgemFraxlendConfig, WstGBPFrxUSDConstants) returns (address) {
        return _oracle;
    }

    function configDataX() external view returns (bytes memory) {
        return _configData(ORACLE());
    }

    function preflightX() external view {
        _preflight();
    }

    function assertPairX(IFraxlendPair pair_) external view {
        _assertPair(pair_);
    }
}

/// @notice Fork tests for deployment through the live FraxlendPairDeployer and pair operations.
/// @dev The whitelisted deployer is impersonated and the wsgem banlist check is mocked to allow
///      the test accounts.
contract WstGBPFrxUSDPairForkTest is Test {
    address internal constant FRAX_DEPLOYER_EOA = 0xa4EC124e09D6D1A092c6BD16aFac9CD83f73E3c3;

    MarketScriptHarness internal harness;
    WsgemFraxlendDualOracle internal oracle;
    IFraxlendPair internal pair;

    address internal wstgbp;
    address internal frxusd;

    address internal lender = makeAddr("lender");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("ETH_FORK_BLOCK"));

        harness = new MarketScriptHarness();
        wstgbp = harness.WSGEM();
        frxusd = harness.ASSET();

        // Step 1, as the oracle script would build it.
        oracle = new WsgemFraxlendDualOracle(
            IWsgem(wstgbp),
            frxusd,
            IChainlinkAggregator(harness.GEM_USD_FEED()),
            harness.GEM_USD_MAX_DELAY(),
            IChainlinkAggregator(harness.ASSET_USD_FEED()),
            harness.ASSET_USD_MAX_DELAY(),
            harness.QUOTE_DECIMALS(),
            harness.ORACLE_NAME()
        );
        harness.setOracle(address(oracle));

        // Run the same preflight used by `make market-deploy`.
        harness.preflightX();

        // Step 2, as Frax runs it: their whitelisted EOA calls deploy() on a deployer contract
        // that must already hold the seed liquidity in the asset token.
        // Resolve harness values before `vm.prank`, which applies only to the next external call.
        address deployer_ = harness.PAIR_DEPLOYER();
        bytes memory config_ = harness.configDataX();
        deal(frxusd, deployer_, 1_000_000e18);

        vm.prank(FRAX_DEPLOYER_EOA);
        pair = IFraxlendPair(IFraxlendPairDeployer(deployer_).deploy(config_));
        pair.updateExchangeRate();

        // Pin the banlist check open for every party in this rehearsal. The cop is a default-allow
        // banlist read from tGBP, so production needs no arranging; the selector-wide mock just
        // keeps all test accounts on the unblocked path.
        vm.mockCall(IGatedToken(wstgbp).cop(), abi.encodeWithSelector(ICop.pass.selector), abi.encode(true));

        // Fund the actors and stock the lending side.
        deal(frxusd, lender, 1_000_000e18);
        deal(frxusd, liquidator, 1_000_000e18);
        deal(wstgbp, borrower, 10_000e18);

        vm.startPrank(lender);
        IERC20Minimal(frxusd).approve(address(pair), type(uint256).max);
        pair.deposit(500_000e18, lender);
        vm.stopPrank();
    }

    // --- Helpers -------------------------------------------------------------------------------

    function _addCollateral(uint256 amount_) internal {
        vm.startPrank(borrower);
        IERC20Minimal(wstgbp).approve(address(pair), type(uint256).max);
        pair.addCollateral(amount_, borrower);
        vm.stopPrank();
    }

    /// @dev The pair's own solvency bound: borrow <= maxLTV * collateral / (1e5 * highRate/1e18).
    function _maxBorrow(uint256 collateral_) internal view returns (uint256) {
        (,,,, uint256 high_) = pair.exchangeRateInfo();
        return harness.MAX_LTV() * collateral_ * 1e18 / (1e5 * high_);
    }

    // --- The rehearsal -------------------------------------------------------------------------

    function test_theRealDeployerAcceptsTheConfigDataAndWiresThePairAsEncoded() public view {
        // The script's post-deploy assertion set: every configData field read back off the live
        // pair, plus the exchange-rate round-trip against the oracle.
        harness.assertPairX(pair);

        (,,, uint256 low_, uint256 high_) = pair.exchangeRateInfo();
        (, uint256 oLow_, uint256 oHigh_) = oracle.getPrices();
        assertEq(low_, oLow_);
        assertEq(high_, oHigh_);
    }

    function test_aBorrowJustInsideTheLtvBoundPassesAndJustOutsideReverts() public {
        _addCollateral(1_000e18);
        uint256 max_ = _maxBorrow(1_000e18);

        // ~$1,018 of frxUSD against $1,357 of wstGBP at 75% LTV. Just inside first.
        vm.prank(borrower);
        pair.borrowAsset(max_ * 999 / 1000, 0, borrower);

        // The remaining headroom is ~0.1% of the bound; asking for 2% more must trip solvency,
        // which the pair enforces against priceHigh, the burncost leg. Partial
        // match: Insolvent carries the live borrow/collateral/rate, which this test cannot pin.
        vm.prank(borrower);
        vm.expectPartialRevert(IFraxlendPairErrors.Insolvent.selector);
        pair.borrowAsset(max_ * 20 / 1000, 0, borrower);
    }

    function test_wideningTheQuoteSpreadPastTheGateBlocksNewBorrowsButNotRepay() public {
        _addCollateral(1_000e18);
        vm.prank(borrower);
        pair.borrowAsset(100e18, 0, borrower);

        // Administratively widen the wrapper's spread: mintcost 10% over burncost puts the
        // low/high deviation at ~9%, past the pair's 5% gate.
        uint256 burn_ = IWsgem(wstgbp).burncost();
        vm.mockCall(wstgbp, abi.encodeWithSelector(IWsgem.mintcost.selector), abi.encode(burn_ * 110 / 100));

        // The pair reuses stored rates within one timestamp; a second in, it must consult the
        // oracle again and see the widened spread.
        vm.warp(block.timestamp + 1);
        (bool borrowAllowed_,,) = pair.updateExchangeRate();
        assertFalse(borrowAllowed_);

        vm.prank(borrower);
        vm.expectRevert(IFraxlendPairErrors.ExceedsMaxOracleDeviation.selector);
        pair.borrowAsset(100e18, 0, borrower);

        // The deviation gate blocks new borrowing but not repayment.
        vm.startPrank(borrower);
        IERC20Minimal(frxusd).approve(address(pair), type(uint256).max);
        pair.repayAsset(pair.userBorrowShares(borrower) / 2, borrower);
        vm.stopPrank();
    }

    function test_aWeekOldChainlinkPriceWarnsWithoutBlockingCollateralWithdrawal() public {
        _addCollateral(1_000e18);
        vm.prank(borrower);
        pair.borrowAsset(100e18, 0, borrower);

        // No new rounds can arrive on the pinned fork. A week later both answers are stale, but
        // still positive and well formed, so the oracle serves exactly those prices with a
        // warning instead of reverting.
        vm.warp(block.timestamp + 7 days);
        (bool bad_, uint256 low_, uint256 high_) = oracle.getPrices();
        assertTrue(bad_);
        assertGt(low_, 0);
        assertLe(low_, high_);

        // A debt-bearing borrower must refresh the exchange rate before collateral can leave.
        // This is the user path the warning policy is designed to preserve.
        vm.prank(borrower);
        pair.removeCollateral(1e18, borrower);
        assertEq(pair.userCollateralBalance(borrower), 999e18);

        // Frax's warning is advisory: the same narrow low/high band still permits borrowing.
        // The warning is advisory and does not pause borrowing.
        vm.warp(block.timestamp + 1);
        (bool borrowAllowed_,,) = pair.updateExchangeRate();
        assertTrue(borrowAllowed_);
    }

    function test_aPausedPipFreezesBorrowsAndLiquidationsAlike() public {
        _addCollateral(1_000e18);
        vm.prank(borrower);
        pair.borrowAsset(100e18, 0, borrower);

        // The upstream pause: the pip publishes zero, the oracle reverts, and every price-touching
        // path on the pair reverts with it, including liquidation. The warp steps past the pair's
        // same-timestamp rate reuse so it consults the oracle again.
        vm.mockCall(address(oracle.PIP()), abi.encodeWithSelector(bytes4(keccak256("read()"))), abi.encode(0));
        vm.warp(block.timestamp + 1);

        vm.expectRevert(WsgemFraxlendDualOracle.OraclePaused.selector);
        pair.updateExchangeRate();

        vm.prank(borrower);
        vm.expectRevert(WsgemFraxlendDualOracle.OraclePaused.selector);
        pair.borrowAsset(1e18, 0, borrower);

        vm.prank(liquidator);
        vm.expectRevert(WsgemFraxlendDualOracle.OraclePaused.selector);
        pair.liquidate(1, block.timestamp + 1, borrower);
    }

    function test_anUnderwaterPositionLiquidatesOnceTheLowRateSaysSo() public {
        _addCollateral(1_000e18);
        uint256 borrowed_ = _maxBorrow(1_000e18) * 999 / 1000;
        vm.prank(borrower);
        pair.borrowAsset(borrowed_, 0, borrower);

        // A 40% collateral markdown raises exchange rates by about 1.67x and makes the position
        // liquidatable at priceLow, the mintcost leg.
        uint256 burn_ = IWsgem(wstgbp).burncost();
        uint256 mint_ = IWsgem(wstgbp).mintcost();
        vm.mockCall(wstgbp, abi.encodeWithSelector(IWsgem.burncost.selector), abi.encode(burn_ * 60 / 100));
        vm.mockCall(wstgbp, abi.encodeWithSelector(IWsgem.mintcost.selector), abi.encode(mint_ * 60 / 100));
        vm.warp(block.timestamp + 1); // step past the pair's same-timestamp rate reuse
        pair.updateExchangeRate();

        uint256 sharesBefore_ = pair.userBorrowShares(borrower);
        uint256 collateralBefore_ = pair.userCollateralBalance(borrower);

        vm.startPrank(liquidator);
        IERC20Minimal(frxusd).approve(address(pair), type(uint256).max);
        // A partial liquidation; the exact fee split is the pair's business, not this repo's.
        // The width of the check is that collateral moved to the liquidator and debt shrank.
        // Bounded far below uint128 by the borrow above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 seized_ = pair.liquidate(uint128(sharesBefore_ / 4), block.timestamp + 1, borrower);
        vm.stopPrank();

        assertGt(seized_, 0);
        assertLt(pair.userBorrowShares(borrower), sharesBefore_);
        assertLt(pair.userCollateralBalance(borrower), collateralBefore_);
        assertEq(IERC20Minimal(wstgbp).balanceOf(liquidator), seized_);
    }

    function test_aSolventPositionCannotBeLiquidated() public {
        _addCollateral(1_000e18);
        vm.prank(borrower);
        pair.borrowAsset(100e18, 0, borrower);

        vm.startPrank(liquidator);
        IERC20Minimal(frxusd).approve(address(pair), type(uint256).max);
        vm.expectRevert(IFraxlendPairErrors.BorrowerSolvent.selector);
        pair.liquidate(1, block.timestamp + 1, borrower);
        vm.stopPrank();
    }
}
