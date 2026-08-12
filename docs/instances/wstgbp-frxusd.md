# Instance: wstGBP / frxUSD (Ethereum mainnet)

The first market this repo deploys: **wstGBP collateral, frxUSD asset**, on FraxLend's v5 pair
deployer. Constants live in `script/WstGBPFrxUSD.s.sol` and are pinned byte-for-byte by
`test/WstGBPFrxUSDDeployScript.t.sol`; this sheet is the human-readable side of that double entry.

## Deployment state

| Step | Status | Address |
|---|---|---|
| 1. `WsgemFraxlendDualOracle` | **not yet deployed** — run `make oracle-deploy INSTANCE=WstGBPFrxUSD` | — |
| 2. Frax whitelisting review | pending step 1 | — |
| 3. FraxLend pair | pending steps 1–2 | — |

After step 1: write the oracle address into `ORACLE()` in `script/WstGBPFrxUSD.s.sol`, change
`test_theOracleWriteBackSlotStartsUnset` to pin that exact address, verify the source on Etherscan,
and update this table. Follow the evidence and recovery checklist in
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

Based on the live frxUSD/KRWQ reference pair (`0x00C242cA3Ef5c2CB909ed3eD972B6f24624B4337`,
registry #71), the newest fiat-pegged 18-decimal collateral on the v5 deployer. The proposal
intentionally tightens `maxOracleDeviation` from the reference pair's live 10% to 5%; the other
listed risk parameters follow the reference configuration:

| Field | Value | Meaning |
|---|---|---|
| asset | frxUSD (above) | the token lent |
| collateral | wstGBP (above) | the token pledged |
| oracle | *step-1 address* | this repo's dual oracle |
| maxOracleDeviation | 5,000 | Intentional 5% gate, stricter than the reference pair's live 10%; everyday deviation is ~250 |
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

1. **Oracle address + verified source** (from step 1; Etherscan link).
2. **What it is**: an ownerless, stateless `IDualOracle` (id `0x415f1303`, ERC-165-registered).
   `priceHigh` = wstGBP's on-chain redemption quote × Chainlink GBP/USD ÷ Chainlink frxUSD/USD,
   inverted to collateral-per-asset; `priceLow` = the same through the issuance quote. No owner,
   no setters; anything unusable — including a feed past its immutable 86,700 s staleness
   bound — reverts, freezing the pair rather than pricing it (`isBadData` is always false: with
   both legs on shared feeds, staleness never widens the deviation gate, so a flag would protect
   nothing).
3. **Sample output**: `getPrices()` at block 25,730,000 → `(false, 734035945961033381,
   735875635048655018)`; deviation 249/1e5.
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

## Related deployments of the same collateral

| Venue | Oracle | Status |
|---|---|---|
| Morpho Blue | `MorphoChainlinkOracleV2` over the 8-dp burncost aggregator `0xF7493C2739c2b1bF5E6bB0e5b16A265Ed0B400B0` | live |
| LlamaLend (crvUSD) | `WsgemLlamalendOracle` `0xdc85a32D5B93e040A4e84401D567DcE02237557C` | live |
| LlamaLend (frxUSD) | `WsgemFxLlamalendOracle` | dry-run only |
| FraxLend (frxUSD) | this repo | pre-deploy |
