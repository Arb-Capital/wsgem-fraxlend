# Design

The oracle is a passthrough. Everything below is about making a passthrough safe to stand between
an administered NAV feed and a lending market. Two FraxLend behaviors are especially relevant:
its price direction is inverted, and its bad-data flag is advisory.

## 1. The price direction

FraxLend's `getPrices()` returns **collateral-per-asset**: the amount of collateral token, at the
collateral's native decimals, that 1e18 (wei) of the asset buys. The pair's LTV arithmetic is

```
LTV = (borrowAmount * exchangeRate / 1e18) * 1e5 / collateralAmount
```

so for the units to cancel, `exchangeRate` must be collateral-wei per 1e18 asset-wei. With
`P_a` = USD per asset token and `P_c` = USD per wsgem:

```
price = 1e18 * (P_a / P_c) * 10^(collateralDecimals - assetDecimals),   collateralDecimals = 18
```

Substituting the raw sources — `P_a = assetRaw / 10^assetFeedDec` from the asset/USD feed, and
`P_c = quoteRaw * gemRaw / 10^(quoteDec + gemFeedDec)` from the wsgem quote times the gem-currency
feed — and folding every power of ten:

```
price = assetRaw * PRICE_SCALE / (quoteRaw * gemRaw)
PRICE_SCALE = 10^(36 - assetDec - assetFeedDec + quoteDec + gemFeedDec)
```

Every decimals input is capped at 18 in the constructor, so the exponent sits in [0, 72] —
provably non-negative — and one immutable multiplier covers every configuration with no direction
branch. For wstGBP/frxUSD (18-decimal tokens, 8-decimal feeds): `PRICE_SCALE = 1e36`.

Worked check at the fork-pinned block (25,730,000): `burncost = 1.005530e18` tGBP,
`GBP/USD = 1.35139e8`, `frxUSD/USD = 0.99995412e8` → `priceHigh = 735875635048655018`. One wstGBP
is worth $1.3589, and 1e18 of frxUSD buys 0.7359e18 of it. Floor division on both legs: at 1e18
scale the ±1 wei difference is negligible relative to the wrapper's 25 bp spread.

## 2. The inversion: which quote is "low"?

Because the price is inverted, the *cheaper* dollar valuation of the collateral produces the
*larger* number:

| leg | wsgem quote | direction of conservatism | FraxLend slot | used for |
|---|---|---|---|---|
| high | `burncost()` (NAV net of exit spread) | values collateral at what redemption pays | `priceHigh` | borrow solvency: `_isSolvent(borrower, highExchangeRate)` |
| low | `mintcost()` (NAV plus issuance spread) | values collateral at what replacement costs | `priceLow` | liquidation trigger and collateral-seized sizing |

The band between them is the wrapper's primary-market spread. While minting and redemption are
open, prices outside that band create an arbitrage against the wrapper. Borrowing is capped at the
pessimistic edge; liquidation starts past the optimistic one. The two spreads are independently
settable upstream, so `mintcost >=
burncost` is an expectation, not an invariant: the oracle sorts its outputs and the deviation gate
(`1e5 * (high - low) / high`, 25 bp today against a 5% gate) is what turns an administratively
widened spread into a borrowing halt rather than a mispricing.

## 3. Warn on stale, revert on unusable

`isBadData` does not stop a FraxLend pair — `_updateExchangeRate` emits `WarnOracleData` and uses
the returned prices regardless. An oracle that "fails safe" by returning a placeholder alongside
`isBadData = true` has therefore failed dangerous: the placeholder prices positions. This oracle
only warns when it still has a real price to serve: a positive, well-formed Chainlink answer older
than its staleness bound (86,700 s = heartbeat + 300). It returns that last answer with
`isBadData = true`; fresh answers return `false`.

That policy follows Frax's own stale-route convention and prioritizes market continuity. If a feed
stops publishing, withdrawals, repayments and liquidations remain available. The trade-off is
unavoidable at the oracle layer: new borrowing also remains open at the stale FX price because
FraxLend treats the flag as advisory and both returned prices share the same feeds, so their
deviation does not widen. Monitoring must escalate the warning, and a permanently discontinued
feed requires a replacement oracle plus a Frax-governance migration.

The oracle still **reverts** when it cannot form a valid price: paused pip (`OraclePaused`), zero
quote (`InvalidQuote`), non-positive / zero-stamped / future-stamped Chainlink answer
(`InvalidFeedAnswer`), a composition that floors to zero (`InvalidPrice`), any upstream revert, or
checked-arithmetic overflow. Those states cannot be repaired by attaching a warning to a
placeholder. A pip pause remains a freeze because the upstream protocol has halted
redemptions and publishes no usable NAV.

## 4. Pip first

`burncost()` and `mintcost()` resolve through the wsgem's upgradeable gate contract. The gate may
return a nonzero quote while the pip is paused. Because the pip is the pause authority,
`pip.read()` is checked before either quote.

## 5. Excluded features

- **No owner, no timelock, no settable delays.** Frax's own oracles carry `Timelock2Step` and a
  settable `maximumOracleDelay`; this one is a passthrough of an already-administered price and
  does not add a second administrative role. A Chainlink heartbeat change means a
  redeploy (stateless, so a replacement costs only gas) and a governance oracle swap on the pair.
- **No frxUSD hard-peg assumption.** This oracle reads the frxUSD/USD feed, so a depeg moves the
  price instead of silently mispricing collateral.
  A same-currency market (asset in the gem's own currency) passes the same feed for both legs and
  the FX cancels exactly.
- **No NAV-cadence assumption.** The pip publishes weekly today and may become per-block; nothing
  here reads or stores a cadence. Staleness bounds exist only on the Chainlink legs, which do
  carry publication times.
- **No round history, no events.** FraxLend reads the current price; this oracle does not duplicate
  upstream feed history.

## 6. The metadata surface

The pair calls only `getPrices()`. The rest of `IDualOracle` — `ORACLE_PRECISION`,
`BASE_TOKEN_*`/`QUOTE_TOKEN_*` (USD sentinel `address(840)` against the collateral, per Frax
convention), `NORMALIZATION_*` (zero for an 18-decimal collateral, so `getPricesNormalized()` is
the identity), `decimals()` (18), `name()`, ERC-165 — exists for Frax's tooling and review. The
expected interface id is `0x415f1303`, which **excludes** the `CHAINLINK_FEED_ADDRESS()` getter
from the registered member set; the local declaration is pinned by both the unit and fork suites.
