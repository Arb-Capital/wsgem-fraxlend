# Instance: wstGBP / frxUSD (Ethereum mainnet)

The first market this repo deploys: **wstGBP collateral, frxUSD asset**, on FraxLend's v5 pair
deployer. Constants live in `script/WstGBPFrxUSD.s.sol` and are pinned byte-for-byte by
`test/WstGBPFrxUSDDeployScript.t.sol`; this sheet is the human-readable side of that double entry.

## Deployment state

| Step | Status | Address |
|---|---|---|
| 1. `WsgemFraxlendDualOracle` | **deployed** 2026-08-11, block 25,736,263; [source verified](https://etherscan.io/address/0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407#code) | [`0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407`](https://etherscan.io/address/0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407) |
| 2. Frax whitelisting review | **next** — send the hand-off package below | — |
| 3. FraxLend pair | pending step 2 | — |

Step 1's deployment transaction is
`0xf408d18c4dda25eed43aea4b5906e85b47fb3ff82861027d5dfee85f3b5dd921`; at deployment the oracle
reported `getPrices()` → `(false, 734141221132615161, 735981174067784622)`, deviation 249/1e5.
The write-back is committed: `ORACLE()` in `script/WstGBPFrxUSD.s.sol` records the address and
`test_theOracleWriteBackSlotPinsTheDeployedAddress` pins it. Next: run
`make predeploy-market INSTANCE=WstGBPFrxUSD` and send the printed configData with the hand-off
below, following the evidence and recovery checklist in
[the deployment runbook](../deployment-runbook.md).

## The oracle's wiring

| Parameter | Value | Provenance |
|---|---|---|
| wsgem / collateral | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | wstGBP, 18 dp; non-rebasing wrapper, NAV accrues against tGBP; transfers screened by a tGBP-administered banlist |
| gem | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` | tGBP, 18 dp; cross-checked against `wsgem.gem()` in preflight |
| asset | `0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29` | frxUSD, 18 dp — **not** legacy FRAX `0x853d955a…` |
| gem/USD feed | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` | Chainlink GBP/USD: 8 dp, 24 h heartbeat, 0.15% deviation trigger |
| asset/USD feed | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | Chainlink frxUSD/USD: 8 dp, 24 h heartbeat, 0.5% — **not** FRAX/USD `0xB9E1E3A9…` |
| max delays | 86,700 s both legs | Frax convention: heartbeat + 300 s; immutable (ownerless) |
| quote decimals | 18 | tGBP's decimals — the scale of `burncost()`/`mintcost()` |
| `PRICE_SCALE` | 1e36 | `10^(36 − 18 − 8 + 18 + 8)`; see docs/00-design.md §1 |
| name | `frxUSD/wstGBP DualOracle` | 24 bytes; follows Fraxlend's collateral-per-asset output direction |

## Live worked numbers (block 25,730,000, the fork-test pin)

```
burncost           1005529808480920241      (tGBP per wstGBP)
mintcost           1008049933314205755
GBP/USD            135139000                (1.35139, 8 dp)
frxUSD/USD          99995412                (0.99995, 8 dp)

priceHigh          735875635048655018       = frxRaw * 1e36 / (burncost * gbpRaw)
priceLow           734035945961033381       = frxRaw * 1e36 / (mintcost * gbpRaw)
deviation          249 / 1e5                (~25 bp -- the wrapper's exit spread)
implied value      1 wstGBP = $1.3589 at the burncost leg
```

Direction check: collateral worth more than the asset prices **below** 1e18 in FraxLend's
collateral-per-asset convention. The sanity band in the instance file (`4e17 .. 1e18`) brackets
GBP/USD from parity to $2.50 with the NAV at or above par; a decimal slip lands orders of
magnitude outside it and fails the preflight.

## Proposed pair configData

The proposed parameters set a 5% `maxOracleDeviation`, comfortably above the wrapper's ordinary
~25 bp mint/burn spread while still halting new borrowing if that spread widens materially:

| Field | Value | Meaning |
|---|---|---|
| asset | frxUSD (above) | the token lent |
| collateral | wstGBP (above) | the token pledged |
| oracle | `0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407` | this repo's dual oracle (step 1, above) |
| maxOracleDeviation | 5,000 | 5% gate; everyday deviation is ~250 |
| rateContract | `0x987a96c6637cF7E7B369BA7C1110d5fB69fb2d17` | Variable Rate V3, as on every current frxUSD pair |
| fullUtilizationRate | 9,494,822,760 | ~30% APR seed at full utilization (per-second, 1e18) |
| maxLTV | 75,000 | 75% at 1e5 |
| liquidationFee | 5,000 | 5% clean; pair derives dirty at 90% of it |
| protocolLiquidationFee | 2,000 | 2% at 1e5 |

`make configdata INSTANCE=WstGBPFrxUSD` prints the ABI-encoded 288-byte blob (after step 1's
write-back) plus this table with live prices; the encoding itself is pinned against hand-built
bytes in the pin suite and accepted by the real deployer in the fork rehearsal.

## Whitelisting hand-off (for the Frax team)

FraxLend `deploy()` is whitelist-gated, so this is a request to review the oracle and either run
`deploy(configData)` from a whitelisted sender or whitelist ours. The package:

1. **Oracle address + verified source**:
   [`0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407`](https://etherscan.io/address/0xA15A2aF6CaA24d0057b5EEFAcc2046E5161Da407#code)
   (deployed 2026-08-11, block 25,736,263).
2. **What it is**: an ownerless, stateless `IDualOracle` (id `0x415f1303`, ERC-165-registered).
   `priceHigh` = wstGBP's on-chain redemption quote × Chainlink GBP/USD ÷ Chainlink frxUSD/USD,
   inverted to collateral-per-asset; `priceLow` = the same through the issuance quote. No owner,
   no setters. A positive, well-formed feed answer past its immutable 86,700 s freshness bound is
   served as the last price with `isBadData = true`, preserving withdrawals, repayments and
   liquidations if publication stops. The Frax warning is advisory, so new borrowing also remains
   possible at that stale FX price. Data from which no valid price can be formed still reverts.
3. **Sample output**: `getPrices()` at the deployment block 25,736,263 → `(false,
   734141221132615161, 735981174067784622)`; at the fork-test pin block 25,730,000 → `(false,
   734035945961033381, 735875635048655018)`; deviation 249/1e5 at both.
4. **The configData** (from `make configdata`), field-decoded as in the table above.
5. **Rehearsal evidence**: `test/fork/WstGBPFrxUSDPair.fork.t.sol` runs the v5 deployer's
   `deploy()` with these exact bytes on a mainnet fork (whitelisted sender impersonated, deployer
   seeded), then exercises borrows at the LTV bound, the deviation gate, the pause freeze, and a
   liquidation against the resulting pair.
6. **Deployment funding**: the v5 deployer must hold Frax's configured frxUSD seed before calling
   `deploy(configData)`. Its balance was zero during the 2026-08-11 pre-deployment review, so Frax
   must fund it immediately before deployment and confirm the required seed amount.
7. **Compliance note**: wstGBP transfers consult a permissive banlist administered on tGBP
   (default-allow; wstGBP does not control it), so no allowlisting step is needed for the pair.
   The residual cases are remote but worth knowing: a banlisted address cannot receive seized
   collateral, and a banlisted pair would freeze collateral movement.
