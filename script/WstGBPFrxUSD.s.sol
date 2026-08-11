// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Arb Capital
pragma solidity ^0.8.28;

import {
    WsgemFraxlendConfig,
    WsgemFraxlendOracleScript,
    WsgemFraxlendMarketScript
} from "./WsgemFraxlendDeploy.s.sol";

/// @title  WstGBPFrxUSDConstants
/// @notice The wstGBP-collateral / frxUSD-asset instance. This file (with docs/) is the only
///         place in the repo that names a token; everything above it is generic.
///
/// @dev Every value is `pure`, every value is pinned byte-for-byte by
///      `test/WstGBPFrxUSDDeployScript.t.sol`, and every address states its provenance. A new
///      wsgem market is a new sibling of this file, never an edit to `script/` generics or
///      `src/`.
abstract contract WstGBPFrxUSDConstants is WsgemFraxlendConfig {
    // --- Chain and FraxLend infrastructure -----------------------------------------------------

    /// @dev Every address below is an Ethereum mainnet address and means nothing anywhere else.
    function CHAIN_ID() public pure virtual override returns (uint256) {
        return 1;
    }

    /// @dev `FraxlendPairDeployer` v5 (version() = 5,0,0) -- the one deploying today's
    ///      frxUSD-asset pairs. NOT the v1 deployer at 0x38488dE9...: that one decodes a
    ///      different, ten-field configData and predates the dual-oracle interface.
    function PAIR_DEPLOYER() public pure virtual override returns (address) {
        return 0xF767A82a188305461b6f01a7706f7Bc0ba941ffF;
    }

    /// @dev The whitelist the v5 deployer consults (its `fraxlendWhitelistAddress()`), read back
    ///      and cross-checked in the market preflight. deploy() is gated on
    ///      `fraxlendDeployerWhitelist(msg.sender)`; as of 2026-08 only Frax's own deployer EOA
    ///      is listed, so the operational path is handing Frax the configData this repo prints.
    function WHITELIST() public pure virtual override returns (address) {
        return 0xDc1cf6863b6100468479fE7dd3D2D1cDe7775265;
    }

    // --- The oracle's wiring -------------------------------------------------------------------

    /// @dev wstGBP, the wsgem: 18 decimals, non-rebasing, NAV accrues against tGBP. Transfers are
    ///      compliance-gated (`canPass`), which a FraxLend pair tolerates -- the gate must simply
    ///      allow the pair itself to hold the token before the market can custody collateral.
    function WSGEM() public pure virtual override returns (address) {
        return 0x57C3571f10767E49C9d7b60feb6c67804783B7aE;
    }

    /// @dev tGBP, the gem: 18 decimals. Cross-checked against `wsgem.gem()` in preflight.
    function GEM() public pure virtual override returns (address) {
        return 0x27f6c8289550fCE67f6B50BeD1F519966aFE5287;
    }

    /// @dev frxUSD, 18 decimals -- and NOT legacy FRAX 0x853d955aCEf822Db058eb8505911ED77F175b99e,
    ///      which still exists, still trades, and is one paste away. Every current FraxLend pair
    ///      lends frxUSD; a pair against legacy FRAX would be an orphan with a mispriced oracle.
    function ASSET() public pure virtual override returns (address) {
        return 0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29;
    }

    /// @dev Chainlink GBP/USD: 8 decimals, 24 h heartbeat, 0.15% deviation trigger. Publishes
    ///      through weekends.
    function GEM_USD_FEED() public pure virtual override returns (address) {
        return 0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5;
    }

    /// @dev Chainlink frxUSD/USD: 8 decimals, 24 h heartbeat, 0.5% deviation trigger. NOT the
    ///      legacy FRAX/USD feed 0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD -- same hazard as
    ///      `ASSET()`, one address apart from a silently wrong market.
    function ASSET_USD_FEED() public pure virtual override returns (address) {
        return 0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83;
    }

    /// @dev Frax's own staleness convention for a 24 h feed: heartbeat + 300 s grace, exactly the
    ///      86,700 the live reference dual oracle uses. Immutable on the oracle -- there is no
    ///      owner to retune it -- and a feed lapse past the bound REVERTS (freezing the pair), so
    ///      a Chainlink heartbeat change means a redeploy plus a governance oracle swap.
    function GEM_USD_MAX_DELAY() public pure virtual override returns (uint256) {
        return 86_700;
    }

    function ASSET_USD_MAX_DELAY() public pure virtual override returns (uint256) {
        return 86_700;
    }

    /// @dev tGBP's decimals, i.e. the scale of `wstGBP.burncost()`. Cross-checked in preflight
    ///      against the gem's real `decimals()` -- this constant is what the price fold is built
    ///      from, and inheriting it silently is how a mis-scaled market happens.
    function QUOTE_DECIMALS() public pure virtual override returns (uint8) {
        return 18;
    }

    /// @dev 24 bytes; the oracle packs it into one immutable word (32-byte cap).
    function ORACLE_NAME() public pure virtual override returns (string memory) {
        return "wstGBP/frxUSD DualOracle";
    }

    /// @dev Write-back slot: `address(0)` until `make oracle-deploy INSTANCE=WstGBPFrxUSD` has
    ///      broadcast, then the deployed address goes here (a committed, reviewable edit). The
    ///      market target refuses to run while this is unset, and the oracle target refuses to
    ///      run AGAIN while it is set. The one getter left `view` rather than `pure`: the pair
    ///      fork rehearsal must substitute a step-1 oracle that only exists inside its fork, and
    ///      Solidity will not loosen a `pure` override back to `view`.
    function ORACLE() public view virtual override returns (address) {
        return address(0);
    }

    // --- The pair's configData -----------------------------------------------------------------
    //
    // Matched to the live frxUSD/KRWQ reference pair (registry #71) -- the newest fiat-pegged
    // 18-decimal collateral on the v5 deployer, and the closest structural relative of this
    // market. The Frax team has final say on all five; these are the proposal.

    /// @dev 5% at 1e5 precision. The oracle's own low/high spread is the wrapper's mint/burn
    ///      band, ~25 bp today, so the everyday deviation sits two orders inside the gate; the
    ///      gate only closes borrowing if the spreads are administratively widened past 5%.
    function MAX_ORACLE_DEVIATION() public pure virtual override returns (uint32) {
        return 5_000;
    }

    /// @dev Variable Rate V3 ("[settable0@.875 25-10k] 2 days (.75-.85)") -- the rate contract on
    ///      every current frxUSD pair. Vertex at 87.5% utilization, 2-day rate half-life.
    function RATE_CONTRACT() public pure virtual override returns (address) {
        return 0x987a96c6637cF7E7B369BA7C1110d5fB69fb2d17;
    }

    /// @dev The reference pair's seed: ~30% APR at full utilization, per-second 1e18 rate. Must
    ///      sit inside the rate contract's [MIN, MAX] full-utilization band; V3's floor is ~25%.
    function FULL_UTILIZATION_RATE() public pure virtual override returns (uint64) {
        return 9_494_822_760;
    }

    /// @dev 75% at 1e5 precision -- the reference pair's value and FraxLend's usual for
    ///      fiat-pegged collateral.
    function MAX_LTV() public pure virtual override returns (uint256) {
        return 75_000;
    }

    /// @dev 5% clean at 1e5 precision; the pair derives dirty liquidation at 90% of this (4.5%).
    function LIQUIDATION_FEE() public pure virtual override returns (uint256) {
        return 5_000;
    }

    /// @dev 2% of the liquidation fee to the protocol, 1e5 precision.
    function PROTOCOL_LIQUIDATION_FEE() public pure virtual override returns (uint256) {
        return 2_000;
    }

    // --- Sanity band ---------------------------------------------------------------------------
    //
    // Collateral-per-asset: ~7.36e17 wstGBP per 1e18 frxUSD at GBP/USD 1.35 and NAV ~1.007. The
    // band is deliberately NOT derived from those live numbers: it brackets where the price can
    // plausibly BE -- GBP/USD anywhere in 1.00..2.50 with the NAV at or above par -- and a
    // decimal slip lands orders of magnitude outside it.

    function MIN_PRICE() public pure virtual override returns (uint256) {
        return 4e17;
    }

    function MAX_PRICE() public pure virtual override returns (uint256) {
        return 1e18;
    }
}

/// @title  WstGBPFrxUSDOracleScript
/// @notice `make oracle-dry INSTANCE=WstGBPFrxUSD` / `make oracle-deploy INSTANCE=WstGBPFrxUSD`.
contract WstGBPFrxUSDOracleScript is WsgemFraxlendOracleScript, WstGBPFrxUSDConstants {}

/// @title  WstGBPFrxUSDMarketScript
/// @notice `make configdata INSTANCE=WstGBPFrxUSD` prints the deploy() bytes for the Frax team;
///         `make market-deploy INSTANCE=WstGBPFrxUSD` broadcasts them, whitelisted senders only.
contract WstGBPFrxUSDMarketScript is WsgemFraxlendMarketScript, WstGBPFrxUSDConstants {}
