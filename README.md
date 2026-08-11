# wsgem-fraxlend

An ownerless [FraxLend](https://docs.frax.finance/fraxlend/fraxlend-overview) dual oracle for
wsgem collateral against a USD-stable asset, plus the pair-deployment scripting around it. First
instance: **wstGBP collateral / frxUSD asset** on Ethereum mainnet.

## What the oracle is

`src/WsgemFraxlendDualOracle.sol` — one stateless, immutable contract, generic over any wsgem (an
ERC-20 wrapper whose value accrues against an underlying `gem`, priced by a `pip` NAV feed). It
passes the wrapper's own primary-market quotes through to FraxLend:

- **`burncost()`** — the redemption quote (NAV net of exit spread) — values the collateral for
  **borrowing**;
- **`mintcost()`** — the issuance quote — values it for **liquidation**;
- two Chainlink fiat legs (gem-currency/USD and asset/USD) carry both into the asset's terms.

No owner, no timelock, no setters, no storage. To retune or rename, deploy again.

## Direction, spelled out once

FraxLend prices are **collateral-per-asset**: `getPrices()` returns how much collateral 1e18 of
the asset buys ("the amount of collateral to buy 1e18 asset" — FraxlendPairCore). That inverts
the intuitive quote, and with it the low/high mapping:

| wsgem quote | USD value of collateral | collateral-per-asset | becomes | the pair uses it for |
|---|---|---|---|---|
| `burncost()` | lower  | **larger**  | `priceHigh` | borrow solvency (conservative) |
| `mintcost()` | higher | **smaller** | `priceLow`  | liquidation trigger + sizing |

So the economics read exactly as intended: you may only borrow against what redemption actually
pays, and you are only liquidated against the price at which replacement collateral can actually
be minted. With wstGBP ≈ $1.36, `getPrices()` returns ≈ `7.36e17` — **below** 1e18, and that is
correct.

The full derivation (and the folded `PRICE_SCALE` arithmetic) is argued in
[docs/00-design.md](docs/00-design.md).

## Failure policy: revert is the failure mode

A FraxLend pair treats the oracle's `isBadData` as a warning — it emits an event and uses the
prices anyway. So unusable data (paused pip, zero quote, non-positive, malformed **or stale**
Chainlink answer) **reverts**, which freezes the pair: no new borrows, no liquidations, until the
data returns. Staleness gets no gentler treatment because both legs share the same fiat feeds: a
frozen feed moves low and high together, the deviation gate the flag could have alerted never
widens, and borrowing against old FX data would stay open. `isBadData` is therefore always
false — this oracle refuses rather than warns. The pip is read first and is the sole pause
authority; the wsgem's NAV cadence is administered upstream (weekly today, possibly per-block
later — nothing here assumes either).

## Layout

```
src/WsgemFraxlendDualOracle.sol   the oracle -- the audited surface; names no token
src/interfaces/                   locally declared interfaces; nothing vendored
script/WsgemFraxlendDeploy.s.sol  generic config + preflight + deploy + configData encoder
script/WstGBPFrxUSD.s.sol         the wstGBP/frxUSD instance -- the only file naming tokens
test/                             unit + pin suites (no RPC), test/fork/ (mainnet fork)
docs/                             design argument, instance sheets, address reference
```

## Deploying a market

FraxLend pair deployment is **whitelist-gated**: `FraxlendPairDeployer.deploy()` only accepts
whitelisted senders, and in practice the Frax team runs it. The order is:

1. `make oracle-dry INSTANCE=WstGBPFrxUSD` — keyless simulation of the oracle deploy.
2. `make oracle-deploy INSTANCE=WstGBPFrxUSD` — broadcast + Etherscan verify (keystore signing;
   see `.env.example`).
3. Write the deployed address into `ORACLE()` in `script/WstGBPFrxUSD.s.sol` (the market target
   refuses to run until this is done; the oracle target refuses to run again after it is).
4. `make configdata INSTANCE=WstGBPFrxUSD` — validates the recorded oracle against live state and
   prints the 288-byte `configData` plus a decode table. **This is the hand-off artifact**: send
   it with the whitelisting request in
   [docs/instances/wstgbp-frxusd.md](docs/instances/wstgbp-frxusd.md) to the Frax team.
5. If (and only if) the sender is whitelisted: `make market-deploy INSTANCE=WstGBPFrxUSD` runs
   `deploy()` directly and asserts the resulting pair field by field.

A future wsgem market is a new sibling of `script/WstGBPFrxUSD.s.sol` plus its pin test and
instance sheet — never an edit to `src/` or the generic scripts.

## Tests

```
make test        # unit + pin suites; no RPC
make test-fork   # mainnet fork at a pinned block; needs ETH_RPC_URL
```

The fork suite deploys the oracle through the production script path against live state, pins the
`IDualOracle` interface id against Frax's deployed reference oracle, and rehearses the entire
pair deployment by impersonating the whitelisted deployer: real `deploy()`, real borrows at the
LTV bound, the deviation gate closing, the pip-pause freeze, and a liquidation.
