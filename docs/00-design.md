# Design

The oracle is a passthrough. Everything below is about making a passthrough safe to stand between
an administered NAV feed and a lending market, in a protocol whose oracle interface has two sharp
edges: an inverted price direction, and an advisory-only bad-data flag.

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
scale the ±1 wei is noise against the wrapper's 25 bp spread, and directional-rounding theater on
top of a sorted pair earns nothing.

## 2. The inversion: which quote is "low"?

Because the price is inverted, the *cheaper* dollar valuation of the collateral produces the
*larger* number:

| leg | wsgem quote | direction of conservatism | FraxLend slot | used for |
|---|---|---|---|---|
| high | `burncost()` (NAV net of exit spread) | values collateral at what redemption pays | `priceHigh` | borrow solvency: `_isSolvent(borrower, highExchangeRate)` |
| low | `mintcost()` (NAV plus issuance spread) | values collateral at what replacement costs | `priceLow` | liquidation trigger and collateral-seized sizing |

The band between them is the wrapper's own primary-market spread — the one corridor no secondary
price can durably leave while minting and redemption are open, since anything outside it is an
arbitrage against the wrapper. Borrowing is capped at the pessimistic edge; liquidation fires only
past the optimistic one. The two spreads are independently settable upstream, so `mintcost >=
burncost` is an expectation, not an invariant: the oracle sorts its outputs and the deviation gate
(`1e5 * (high - low) / high`, 25 bp today against a 5% gate) is what turns an administratively
widened spread into a borrowing halt rather than a mispricing.

## 3. Revert is the failure mode

`isBadData` does not stop a FraxLend pair — `_updateExchangeRate` emits `WarnOracleData` and uses
the returned prices regardless. An oracle that "fails safe" by returning a placeholder alongside
`isBadData = true` has therefore failed dangerous: the placeholder prices positions. So this
oracle **reverts** on everything unusable — paused pip (`OraclePaused`), zero quote
(`InvalidQuote`), non-positive / zero-stamped / future-stamped Chainlink answer
(`InvalidFeedAnswer`), a leg older than its staleness bound (`StaleFeed`, 86,700 s = heartbeat +
300), a composition that floors to zero (`InvalidPrice`), and any upstream revert or
checked-arithmetic overflow, both propagated deliberately. `isBadData` is kept for interface
fidelity and is always false.

Staleness deserves its own paragraph, because Frax's own oracles *flag* it and serve the price —
and survive doing so only because their two routes are independent (Chainlink against a Curve
EMA). When one route freezes, the live one walks away from it, the low/high deviation widens, and
the pair's deviation gate closes new borrowing by itself. Here both legs share the same two fiat
feeds: a frozen GBP/USD moves `priceLow` and `priceHigh` together, the deviation never leaves the
wrapper's ~25 bp mint/burn spread, and the one mechanism a flag could have alerted is
structurally blind to the degradation. A flagged-but-served stale price would keep borrowing open
against arbitrarily old FX data. Hence: stale reverts, like everything else.

A reverting oracle freezes the pair — no borrows, *and no liquidations*. For an ownerless
passthrough that is the correct terminal state: a paused pip means redemptions are halted, and
nothing on this contract can know a better price meanwhile. This is the exact opposite of the
LlamaLend oracle's never-revert design, because the two protocols invert the meaning of a revert:
Curve's AMM bricks on one, FraxLend merely waits. The cost is explicit: a Chainlink outage past
24 h 5 m halts the market until the feed resumes — the same freeze a pip pause produces, and the
intended one.

## 4. Pip first

`burncost()` and `mintcost()` resolve through the wsgem's gate contract, which sits behind an
upgradeable proxy of its own. A broken or hostile gate could quote nonzero over a paused feed.
Only the pip is the pause authority, so `pip.read()` is consulted first and no quote is accepted
without it. The reads are not folded into one call, on purpose.

## 5. What is deliberately absent

- **No owner, no timelock, no settable delays.** Frax's own oracles carry `Timelock2Step` and a
  settable `maximumOracleDelay`; this one is a passthrough of an already-administered price, and
  the point is not to add a second discretionary party. A Chainlink heartbeat change means a
  redeploy (stateless, so a replacement costs only gas) and a governance oracle swap on the pair.
- **No frxUSD hard-peg assumption.** The reference KRWQ oracle treats frxUSD as $1.00; this one
  reads the frxUSD/USD feed, so a depeg moves the price instead of silently mispricing collateral.
  A same-currency market (asset in the gem's own currency) passes the same feed for both legs and
  the FX cancels exactly.
- **No NAV-cadence assumption.** The pip publishes weekly today and may become per-block; nothing
  here reads or stores a cadence. Staleness bounds exist only on the Chainlink legs, which do
  carry publication times.
- **No round history, no events.** FraxLend reads a spot pair; history lives in the sibling
  aggregator repos that exist to provide it.

## 6. The metadata surface

The pair calls only `getPrices()`. The rest of `IDualOracle` — `ORACLE_PRECISION`,
`BASE_TOKEN_*`/`QUOTE_TOKEN_*` (USD sentinel `address(840)` against the collateral, per Frax
convention), `NORMALIZATION_*` (zero for an 18-decimal collateral, so `getPricesNormalized()` is
the identity), `decimals()` (18), `name()`, ERC-165 — exists for Frax's tooling and review. The
interface id the live reference oracle registers is `0x415f1303`, which **excludes** the
`CHAINLINK_FEED_ADDRESS()` getter its own interface file declares; the local declaration matches
the registered reality, verified on-chain and pinned by both the unit and fork suites.
