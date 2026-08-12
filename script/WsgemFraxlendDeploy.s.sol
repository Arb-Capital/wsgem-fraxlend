// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {WsgemFraxlendDualOracle} from "../src/WsgemFraxlendDualOracle.sol";
import {IDualOracle} from "../src/interfaces/IDualOracle.sol";
import {IWsgem} from "../src/interfaces/IWsgem.sol";
import {IChainlinkAggregator} from "../src/interfaces/IChainlinkAggregator.sol";
import {IDecimals} from "../src/interfaces/IDecimals.sol";
import {IFraxlendPair, IFraxlendPairDeployer, IFraxlendWhitelist} from "../src/interfaces/IFraxlend.sol";

/// @title  WsgemFraxlendConfig
/// @notice Configuration for a wsgem FraxLend pair.
///
/// @dev Getters are `view virtual` rather than `pure` so a test harness can back them with mock
///      addresses. Production instances tighten to `pure` -- Solidity permits an override to
///      restrict mutability, and doing so is what makes the constants constant.
abstract contract WsgemFraxlendConfig {
    // --- Chain and FraxLend infrastructure -----------------------------------------------------

    /// @dev Required on every instance so the preflight cannot inherit a default chain id.
    function CHAIN_ID() public view virtual returns (uint256);
    function PAIR_DEPLOYER() public view virtual returns (address);
    function WHITELIST() public view virtual returns (address);

    // --- The oracle's wiring -------------------------------------------------------------------

    function WSGEM() public view virtual returns (address);
    function GEM() public view virtual returns (address);
    function ASSET() public view virtual returns (address);
    function GEM_USD_FEED() public view virtual returns (address);
    function GEM_USD_MAX_DELAY() public view virtual returns (uint256);
    function ASSET_USD_FEED() public view virtual returns (address);
    function ASSET_USD_MAX_DELAY() public view virtual returns (uint256);

    /// @dev Required because it determines the price scale. Preflight checks it against the gem.
    function QUOTE_DECIMALS() public view virtual returns (uint8);
    function ORACLE_NAME() public view virtual returns (string memory);

    /// @dev The deployed oracle. It remains zero until the address is committed to the instance
    ///      file after deployment and review.
    function ORACLE() public view virtual returns (address);

    // --- The pair's configData -----------------------------------------------------------------
    //
    // All at FraxLend's 1e5 precision except the utilization rate, which is a per-second 1e18
    // rate. These are proposals: the deploy() call is whitelist-gated, so the Frax team has final
    // say and runs the encoded bytes this repo prints.

    function MAX_ORACLE_DEVIATION() public view virtual returns (uint32);
    function RATE_CONTRACT() public view virtual returns (address);
    function FULL_UTILIZATION_RATE() public view virtual returns (uint64);
    function MAX_LTV() public view virtual returns (uint256);
    function LIQUIDATION_FEE() public view virtual returns (uint256);
    function PROTOCOL_LIQUIDATION_FEE() public view virtual returns (uint256);

    // --- Sanity band ---------------------------------------------------------------------------
    //
    // This independent price band catches decimal errors in the configured inputs. In
    // collateral-per-asset terms, collateral worth more than the asset produces a value below 1e18.

    function MIN_PRICE() public view virtual returns (uint256);
    function MAX_PRICE() public view virtual returns (uint256);
}

/// @title  WsgemFraxlendBase
/// @notice Shared preflight, assertion and reporting for both targets.
abstract contract WsgemFraxlendBase is Script, WsgemFraxlendConfig {
    function _requireCode(address target_, string memory what_) internal view {
        require(target_ != address(0), what_);
        require(target_.code.length != 0, what_);
    }

    /// @dev Reads and validates one Chainlink feed with a feed-specific error prefix.
    function _feedAnswer(address feed_, uint256 maxDelay_, string memory what_) internal view returns (uint256) {
        try IChainlinkAggregator(feed_).latestRoundData() returns (
            uint80, int256 answer_, uint256, uint256 updatedAt_, uint80
        ) {
            require(answer_ > 0, string.concat(what_, "-nonpositive"));
            // forge-lint: disable-next-line(block-timestamp)
            require(updatedAt_ != 0 && updatedAt_ <= block.timestamp, string.concat(what_, "-timestamp"));
            // Deploy only while the runtime warning is clear. Once deployed, the oracle itself
            // serves this same last answer with `isBadData = true` instead of freezing the pair.
            // forge-lint: disable-next-line(block-timestamp)
            require(block.timestamp - updatedAt_ <= maxDelay_, string.concat(what_, "-stale"));
            // Positive by the require above.
            // forge-lint: disable-next-line(unsafe-typecast)
            return uint256(answer_);
        } catch {
            revert(string.concat(what_, "-reverting"));
        }
    }

    /// @dev Recomputes prices from source contracts rather than oracle immutables.
    function _expectedPrices() internal view returns (uint256 low_, uint256 high_) {
        uint256 burn_ = IWsgem(WSGEM()).burncost();
        uint256 mint_ = IWsgem(WSGEM()).mintcost();
        uint256 gemRaw_ = _feedAnswer(GEM_USD_FEED(), GEM_USD_MAX_DELAY(), "preflight/gem-feed");
        uint256 assetRaw_ = _feedAnswer(ASSET_USD_FEED(), ASSET_USD_MAX_DELAY(), "preflight/asset-feed");

        uint256 scale_ = 10
            ** (36
                + uint256(IDecimals(GEM()).decimals())
                + uint256(IChainlinkAggregator(GEM_USD_FEED()).decimals())
                - uint256(IDecimals(ASSET()).decimals())
                - uint256(IChainlinkAggregator(ASSET_USD_FEED()).decimals()));

        high_ = assetRaw_ * scale_ / (burn_ * gemRaw_);
        low_ = assetRaw_ * scale_ / (mint_ * gemRaw_);
        if (low_ > high_) (low_, high_) = (high_, low_);
    }

    /// @dev The gate as FraxlendPairCore computes it, at DEVIATION_PRECISION = 1e5.
    function _deviation(uint256 low_, uint256 high_) internal pure returns (uint256) {
        return 1e5 * (high_ - low_) / high_;
    }

    /// @dev Checks all oracle parameters against the instance configuration before pair deployment.
    function _assertOracle(WsgemFraxlendDualOracle oracle_) internal view {
        require(address(oracle_.WSGEM()) == WSGEM(), "oracle/wsgem");
        require(address(oracle_.PIP()) == IWsgem(WSGEM()).pip(), "oracle/pip");
        require(oracle_.GEM() == GEM(), "oracle/gem");
        require(oracle_.ASSET() == ASSET(), "oracle/asset");
        require(address(oracle_.GEM_USD_FEED()) == GEM_USD_FEED(), "oracle/gem-feed");
        require(oracle_.GEM_USD_MAX_DELAY() == GEM_USD_MAX_DELAY(), "oracle/gem-delay");
        require(address(oracle_.ASSET_USD_FEED()) == ASSET_USD_FEED(), "oracle/asset-feed");
        require(oracle_.ASSET_USD_MAX_DELAY() == ASSET_USD_MAX_DELAY(), "oracle/asset-delay");
        require(oracle_.QUOTE_DECIMALS() == QUOTE_DECIMALS(), "oracle/quote-decimals");
        require(oracle_.BASE_TOKEN_0() == address(840), "oracle/base-token");
        require(oracle_.QUOTE_TOKEN_0() == WSGEM(), "oracle/quote-token");
        require(oracle_.decimals() == 18, "oracle/decimals");
        require(oracle_.supportsInterface(type(IDualOracle).interfaceId), "oracle/interface");
        require(keccak256(bytes(oracle_.name())) == keccak256(bytes(ORACLE_NAME())), "oracle/name");

        (bool bad_, uint256 low_, uint256 high_) = oracle_.getPrices();
        require(!bad_, "oracle/bad-data");
        require(low_ <= high_, "oracle/unsorted");
        require(low_ > 0, "oracle/zero-price");

        (uint256 expLow_, uint256 expHigh_) = _expectedPrices();
        require(low_ == expLow_ && high_ == expHigh_, "oracle/price-mismatch");

        require(low_ >= MIN_PRICE(), "oracle/price-below-band");
        require(high_ <= MAX_PRICE(), "oracle/price-above-band");

        // Reject a configuration that would disable borrowing immediately.
        require(_deviation(low_, high_) <= MAX_ORACLE_DEVIATION(), "oracle/deviation-over-gate");
    }

    /// @dev Nine-field, 288-byte encoding used by the live v5 `FraxlendPairDeployer`.
    function _configData(address oracle_) internal view returns (bytes memory data_) {
        data_ = abi.encode(
            ASSET(), // 1. asset
            WSGEM(), // 2. collateral
            oracle_, // 3. oracle
            MAX_ORACLE_DEVIATION(), // 4. uint32, 1e5 precision
            RATE_CONTRACT(), // 5. rate contract
            FULL_UTILIZATION_RATE(), // 6. uint64, per-second 1e18 rate
            MAX_LTV(), // 7. 1e5 precision
            LIQUIDATION_FEE(), // 8. 1e5 precision ("clean"; dirty is derived at 90%)
            PROTOCOL_LIQUIDATION_FEE() // 9. 1e5 precision
        );
        require(data_.length == 288, "configdata/length");
    }

    /// @dev Shared chain, contract, decimal and price checks. Feeds must be fresh at deployment
    ///      even though runtime staleness only raises a warning.
    function _preflightCommon() internal view {
        require(block.chainid == CHAIN_ID(), "preflight/wrong-chain");

        _requireCode(WSGEM(), "preflight/wsgem-not-a-contract");
        _requireCode(GEM(), "preflight/gem-not-a-contract");
        _requireCode(ASSET(), "preflight/asset-not-a-contract");
        _requireCode(GEM_USD_FEED(), "preflight/gem-feed-not-a-contract");
        _requireCode(ASSET_USD_FEED(), "preflight/asset-feed-not-a-contract");

        require(WSGEM() != ASSET(), "preflight/collateral-is-asset");

        require(IWsgem(WSGEM()).gem() == GEM(), "preflight/gem-mismatch");
        _requireCode(IWsgem(WSGEM()).pip(), "preflight/pip-not-a-contract");

        require(IDecimals(WSGEM()).decimals() == 18, "preflight/wsgem-decimals");
        require(IDecimals(GEM()).decimals() == QUOTE_DECIMALS(), "preflight/quote-decimals");
        require(IDecimals(ASSET()).decimals() <= 18, "preflight/asset-decimals");
        require(bytes(ORACLE_NAME()).length <= 32, "preflight/name-too-long");

        require(IWsgem(WSGEM()).navprice() > 0, "preflight/pip-paused");
        require(IWsgem(WSGEM()).burncost() > 0, "preflight/burncost-zero");
        require(IWsgem(WSGEM()).mintcost() > 0, "preflight/mintcost-zero");

        (uint256 low_, uint256 high_) = _expectedPrices();
        require(low_ > 0, "preflight/price-zero");
        require(low_ >= MIN_PRICE(), "preflight/price-below-band");
        require(high_ <= MAX_PRICE(), "preflight/price-above-band");
    }
}

/// @title  WsgemFraxlendOracleScript
/// @notice Step 1 of 2. Deploys the dual oracle for Frax review.
abstract contract WsgemFraxlendOracleScript is WsgemFraxlendBase {
    function run() external returns (WsgemFraxlendDualOracle oracle_) {
        _preflight();

        vm.startBroadcast();
        oracle_ = new WsgemFraxlendDualOracle(
            IWsgem(WSGEM()),
            ASSET(),
            IChainlinkAggregator(GEM_USD_FEED()),
            GEM_USD_MAX_DELAY(),
            IChainlinkAggregator(ASSET_USD_FEED()),
            ASSET_USD_MAX_DELAY(),
            QUOTE_DECIMALS(),
            ORACLE_NAME()
        );
        vm.stopBroadcast();

        _assertOracle(oracle_);
        _report(oracle_);
    }

    function _preflight() internal view virtual {
        _preflightCommon();

        // Prevent a second deployment while an oracle address is already recorded.
        require(ORACLE() == address(0), "preflight/oracle-already-recorded");
    }

    function _report(WsgemFraxlendDualOracle oracle_) internal view virtual {
        (, uint256 low_, uint256 high_) = oracle_.getPrices();

        console2.log("--- FraxLend dual oracle ----------------------------------------");
        console2.log("oracle:          ", address(oracle_));
        console2.log("name:            ", oracle_.name());
        console2.log("wsgem:           ", WSGEM());
        console2.log("asset:           ", ASSET());
        console2.log("gem/USD feed:    ", GEM_USD_FEED());
        console2.log("asset/USD feed:  ", ASSET_USD_FEED());
        console2.log("max delays:      ", GEM_USD_MAX_DELAY(), ASSET_USD_MAX_DELAY());
        console2.log("priceLow:        ", low_);
        console2.log("priceHigh:       ", high_);
        console2.log("deviation (1e5): ", _deviation(low_, high_));
        console2.log("NEXT: 1. verify the source on the block explorer;");
        console2.log("      2. write this address into the instance file's ORACLE();");
        console2.log("      3. send the whitelisting hand-off (docs/instances/) to the Frax team.");
    }
}

/// @title  WsgemFraxlendMarketScript
/// @notice Step 2 of 2. Validates the recorded oracle against live state, prints the 288-byte
///         configData -- the artifact the Frax team feeds to `deploy()` -- and, when the sender
///         is on Frax's deployer whitelist, broadcasts the deploy itself.
///
/// @dev Pair deployment is whitelist-gated. An unprivileged simulation prints the config data for
///      the Frax team without attempting a transaction.
abstract contract WsgemFraxlendMarketScript is WsgemFraxlendBase {
    function run() external returns (address pair_) {
        _preflight();

        bytes memory configData_ = _configData(ORACLE());
        _reportConfig(configData_);

        if (!IFraxlendWhitelist(WHITELIST()).fraxlendDeployerWhitelist(msg.sender)) {
            // Simulations may print config data, but broadcasts require a whitelisted sender.
            require(!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast), "deploy/sender-not-whitelisted");
            console2.log("sender is not on the FraxLend deployer whitelist; configData above is");
            console2.log("the hand-off artifact. No transaction was attempted.");
            return address(0);
        }

        vm.startBroadcast();
        pair_ = IFraxlendPairDeployer(PAIR_DEPLOYER()).deploy(configData_);
        IFraxlendPair(pair_).updateExchangeRate();
        vm.stopBroadcast();

        _assertPair(IFraxlendPair(pair_));
        _reportPair(IFraxlendPair(pair_));
    }

    function _preflight() internal view virtual {
        _preflightCommon();

        // Report an unset address separately from an address with no code.
        require(ORACLE() != address(0), "preflight/oracle-unset");
        _requireCode(ORACLE(), "preflight/oracle-not-a-contract");

        // The oracle address is written into the instance file by hand, so verify all parameters.
        _assertOracle(WsgemFraxlendDualOracle(ORACLE()));

        _requireCode(PAIR_DEPLOYER(), "preflight/deployer-not-a-contract");
        _requireCode(WHITELIST(), "preflight/whitelist-not-a-contract");
        _requireCode(RATE_CONTRACT(), "preflight/rate-contract-not-a-contract");

        // The v1 deployer uses a different configData layout.
        (uint256 major_,,) = IFraxlendPairDeployer(PAIR_DEPLOYER()).version();
        require(major_ == 5, "preflight/deployer-version");

        require(
            IFraxlendPairDeployer(PAIR_DEPLOYER()).fraxlendWhitelistAddress() == WHITELIST(),
            "preflight/whitelist-mismatch"
        );
    }

    function _assertPair(IFraxlendPair pair_) internal view virtual {
        require(pair_.asset() == ASSET(), "pair/asset");
        require(pair_.collateralContract() == WSGEM(), "pair/collateral");
        require(pair_.rateContract() == RATE_CONTRACT(), "pair/rate-contract");
        require(pair_.maxLTV() == MAX_LTV(), "pair/max-ltv");
        require(pair_.cleanLiquidationFee() == LIQUIDATION_FEE(), "pair/liquidation-fee");
        require(pair_.dirtyLiquidationFee() == LIQUIDATION_FEE() * 90_000 / 1e5, "pair/dirty-liquidation-fee");
        require(pair_.protocolLiquidationFee() == PROTOCOL_LIQUIDATION_FEE(), "pair/protocol-liquidation-fee");

        (address oracle_, uint32 maxDev_,, uint256 low_, uint256 high_) = pair_.exchangeRateInfo();
        require(oracle_ == ORACLE(), "pair/oracle");
        require(maxDev_ == MAX_ORACLE_DEVIATION(), "pair/max-oracle-deviation");

        // Confirm the pair stored the current oracle values.
        (, uint256 oLow_, uint256 oHigh_) = WsgemFraxlendDualOracle(ORACLE()).getPrices();
        require(low_ == oLow_ && high_ == oHigh_, "pair/exchange-rate-mismatch");
    }

    function _reportConfig(bytes memory configData_) internal view virtual {
        console2.log("--- FraxLend pair configData ------------------------------------");
        console2.log("asset:                    ", ASSET());
        console2.log("collateral:               ", WSGEM());
        console2.log("oracle:                   ", ORACLE());
        console2.log("maxOracleDeviation (1e5): ", MAX_ORACLE_DEVIATION());
        console2.log("rateContract:             ", RATE_CONTRACT());
        console2.log("fullUtilizationRate:      ", FULL_UTILIZATION_RATE());
        console2.log("maxLTV (1e5):             ", MAX_LTV());
        console2.log("liquidationFee (1e5):     ", LIQUIDATION_FEE());
        console2.log("protocolLiqFee (1e5):     ", PROTOCOL_LIQUIDATION_FEE());
        console2.log("deployer:                 ", PAIR_DEPLOYER());
        console2.log("configData (288 bytes), for FraxlendPairDeployer.deploy():");
        console2.logBytes(configData_);
    }

    function _reportPair(IFraxlendPair pair_) internal view virtual {
        (,,, uint256 low_, uint256 high_) = pair_.exchangeRateInfo();

        console2.log("--- FraxLend pair -----------------------------------------------");
        console2.log("pair:            ", address(pair_));
        console2.log("lowExchangeRate: ", low_);
        console2.log("highExchangeRate:", high_);
    }
}
