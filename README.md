# wsgem-fraxlend

An ownerless [FraxLend](https://docs.frax.finance/fraxlend/fraxlend-overview) dual oracle for
wsgem collateral against a USD-stable asset, plus the pair-deployment scripting around it. First
instance: **wstGBP collateral / frxUSD asset** on Ethereum mainnet — its oracle is live and
verified at
[`0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407`](https://etherscan.io/address/0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407#code);
the pair awaits Frax's whitelisted deployment
(see [docs/instances/wstgbp-frxusd.md](docs/instances/wstgbp-frxusd.md)).

## What the oracle is

`src/WsgemFraxlendDualOracle.sol` — one stateless, immutable contract, generic over any wsgem (an
ERC-20 wrapper whose value accrues against an underlying `gem`, priced by a `pip` NAV feed). It
passes the wrapper's own primary-market quotes through to FraxLend:

- **`burncost()`** — the redemption quote (NAV net of exit spread) — values the collateral for
  **borrowing**;
- **`mintcost()`** — the issuance quote — values it for **liquidation**;
- two Chainlink fiat legs (gem-currency/USD and asset/USD) carry both into the asset's terms.

No owner, no timelock, no setters, no storage. To retune or rename, deploy again.

## Price direction

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

## Failure policy: warn on stale, revert on unusable

A FraxLend pair treats the oracle's `isBadData` as a warning — it emits an event and uses the
prices anyway. A stale but otherwise valid Chainlink answer is therefore served as the last price
with `isBadData = true`. This keeps withdrawals, repayments and liquidations available if a feed
stops publishing. It also leaves new borrowing open at the stale FX price: the warning is advisory
and the oracle cannot tell an exit from a risk-increasing call. Data from which no valid price can
be formed (paused pip, zero quote, non-positive or malformed Chainlink answer, upstream revert,
zero composed price or overflow) still reverts. The pip is read first and is the sole pause
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
whitelisted senders, and in practice the Frax team runs it. An independent review of the exact
release commit and bytecode is a hard gate. The operational checklist and release-record template
are in [docs/deployment-runbook.md](docs/deployment-runbook.md). The order is:

1. `make predeploy-oracle INSTANCE=WstGBPFrxUSD` — clean-tree, toolchain, local, fork and keyless
   live-deployment checks. The release toolchain is Forge 1.7.1 and Solc 0.8.34.
2. `make oracle-deploy INSTANCE=WstGBPFrxUSD` — broadcast + Etherscan verify (keystore signing;
   see `.env.example`).
3. Write the deployed address into `ORACLE()` in `script/WstGBPFrxUSD.s.sol`, change its pin test
   from zero to that exact address, and update the instance sheet. The market target refuses to
   run until this is done; the oracle target refuses to run again after it is.
4. `make predeploy-market INSTANCE=WstGBPFrxUSD` — reruns every check, validates the recorded
   oracle against live state, and prints the 288-byte `configData` plus a decode table. **This is
   the hand-off artifact**: send it with the whitelisting request in
   [docs/instances/wstgbp-frxusd.md](docs/instances/wstgbp-frxusd.md) to the Frax team.
5. If (and only if) the sender is whitelisted: `make market-deploy INSTANCE=WstGBPFrxUSD` runs
   `deploy()` directly and asserts the resulting pair field by field.

If the oracle transaction lands but automatic source verification fails, do not rerun the deploy.
Recover and verify the existing address using the runbook; a retry would create a second immutable
oracle while `ORACLE()` is still unset.

A future wsgem market should add an instance file beside `script/WstGBPFrxUSD.s.sol`, along with
its pin test and instance sheet, without changing the generic oracle or deployment scripts.

## Tests

```
make check              # format, lint, build, tests, coverage and sizes; no RPC
make test-fork          # mainnet fork at a pinned block; needs ETH_RPC_URL
make predeploy-oracle   # full clean-tree release gate before oracle broadcast
make predeploy-market   # full clean-tree release gate after oracle write-back
```

The fork suite deploys the oracle through the production script path against live state, pins the
expected `IDualOracle` interface id, and rehearses the entire pair deployment by impersonating the
whitelisted deployer: real `deploy()`, real borrows at the LTV bound, the deviation gate closing,
the pip-pause freeze, and a liquidation.
