# Deployment runbook

This is the release gate for the immutable oracle and the subsequent FraxLend pair. A passing
command is necessary but not sufficient: an independent reviewer must sign off on the exact clean
commit and compiler configuration before either broadcast.

## Release record

Create one record for each stage and attach command output plus the independent review report.

| Field | Required value |
|---|---|
| instance / chain | `WstGBPFrxUSD` / Ethereum mainnet (chain id 1) |
| git commit and tag | exact clean commit; signed release tag |
| toolchain | Forge 1.7.1; Solc 0.8.34; Cancun; optimizer enabled, 21,000 runs |
| source review | reviewer, report link/hash, finding disposition, exact covered commit |
| creation bytecode | keccak printed by `make release-info` |
| signer | checksum `ETH_FROM`; confirm it matches the selected keystore |
| execution state | block number, feed rounds/timestamps, prices, deviation and gas quote |
| transaction | hash, receipt status, deployed address and block |
| deployed code | `cast code` keccak and verified-source link |
| hand-off | configData bytes, keccak, decoded fields and Frax recipient/sign-off |

Do not put the RPC URL, Etherscan key, keystore path, password or raw broadcast cache in this
record. The mainnet broadcast JSON under `broadcast/` is reviewable; `cache/` is sensitive and
gitignored.

## Stage 1: oracle

1. Commit every intended source and documentation change. Confirm the independent report covers
   that commit and that no high- or medium-severity finding remains open.
2. Load `.env` from `.env.example`; independently confirm chain id 1, signer/keystore agreement,
   signer ETH balance, and current fee settings. Run:

   ```sh
   make predeploy-oracle INSTANCE=WstGBPFrxUSD
   ```

3. Record the output, current feed timestamps, prices, deviation, commit and creation-bytecode
   hash. Obtain a second-person comparison of every constructor argument to the instance sheet.
4. Broadcast exactly once:

   ```sh
   make oracle-deploy INSTANCE=WstGBPFrxUSD
   ```

5. Confirm the receipt succeeded, source is verified, runtime code is nonempty, and every
   immutable plus `getPrices()` matches the dry-run record. Record the runtime hash with:

   ```sh
   export DEPLOYED_ORACLE=0x...
   cast code "$DEPLOYED_ORACLE" --rpc-url "$ETH_RPC_URL" | cast keccak
   ```

### Verification failure after broadcast

If Forge exits unsuccessfully, inspect `broadcast/WstGBPFrxUSD.s.sol/1/run-latest.json` and the
transaction receipt before doing anything else. If the creation transaction succeeded, **do not
rerun `oracle-deploy`**. Recover the address from the receipt and verify that existing contract:

```sh
export DEPLOYED_ORACLE=0x...
forge verify-contract "$DEPLOYED_ORACLE" \
  src/WsgemFraxlendDualOracle.sol:WsgemFraxlendDualOracle \
  --chain 1 --compiler-version 0.8.34 --num-of-optimizations 21000 \
  --guess-constructor-args --watch --verifier etherscan \
  --rpc-url "$ETH_RPC_URL" --etherscan-api-key "$ETHERSCAN_API_KEY"
```

If the receipt failed or no transaction was sent, diagnose the cause and repeat the dry-run and
second-person review before considering another broadcast.

## Stage 2: pair hand-off

1. Replace the zero returned by `ORACLE()` with the deployed checksum address. Change the pin test
   to assert that exact address, update the instance deployment-state table with its verified link,
   then commit and independently review the write-back.
2. Run `make predeploy-market INSTANCE=WstGBPFrxUSD`. Archive the 288-byte `configData`, its
   `cast keccak` hash, decoded fields, live prices and release identifiers.
3. Frax must confirm the sender is whitelisted and transfer the required frxUSD seed to
   `FraxlendPairDeployer` immediately before `deploy(configData)`. The pre-deployment review found
   its frxUSD balance at zero; the deployer has no public seed-amount getter, so Frax must supply
   that value from its deployment configuration.
4. Frax calls `deploy(configData)`. If this repo's signer has instead been whitelisted, use
   `make market-deploy`; resume a partial broadcast only with `make market-resume`.
5. Confirm registry inclusion, asset, collateral, oracle, 5% maximum deviation, rate contract,
   utilization seed, LTV and both liquidation fees. Confirm `updateExchangeRate()` stores the
   oracle's current low/high values.
6. Have the wstGBP compliance authority allow the pair to hold collateral. Before public launch,
   perform minimal deposit, add-collateral, borrow and repay transactions and confirm an unapproved
   address cannot bypass the token's compliance rules.

## Monitoring and recovery

Monitor both Chainlink round timestamps and answers, the pip value, `burncost()`/`mintcost()`,
low/high deviation, oracle-call reverts, compliance status, upstream proxy implementations and pair
configuration. A stale feed or paused pip intentionally freezes price-dependent pair actions.
There is no oracle administrator: recovery from a permanent upstream/configuration change requires
a replacement oracle and a Frax-governance oracle migration, followed by the same review and
release process.
