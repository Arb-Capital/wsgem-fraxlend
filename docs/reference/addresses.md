# Address reference (Ethereum mainnet)

Every external address this repo touches, in one place. The instance files in `script/` are the
authoritative constants (pinned by the test suite); this sheet is for humans and block explorers.

## Tokens

| Contract | Address | Notes |
|---|---|---|
| wstGBP (wsgem, collateral) | `0x57C3571f10767E49C9d7b60feb6c67804783B7aE` | 18 dp; compliance-gated transfers; `burncost()`/`mintcost()` quotes in tGBP |
| tGBP (gem) | `0x27f6c8289550fCE67f6B50BeD1F519966aFE5287` | 18 dp |
| wstGBP pip (NAV feed) | `0x6A79dCe61A12aa4b75449e0B03746260765D07dF` | behind an upgradeable proxy; `read()` = WAD NAV, 0 = paused; cached by the oracle at construction |
| frxUSD (asset) | `0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29` | 18 dp |
| legacy FRAX — **do not use** | `0x853d955aCEf822Db058eb8505911ED77F175b99e` | still live, one paste away; negative-pinned in the test suite |

## Chainlink feeds

| Feed | Address | Decimals / heartbeat / deviation |
|---|---|---|
| GBP/USD | `0x5c0Ab2d9b5a7ed9f470386e82BB36A3613cDd4b5` | 8 dp / 24 h / 0.15% |
| frxUSD/USD | `0x9B4a96210bc8D9D55b1908B465D8B0de68B7fF83` | 8 dp / 24 h / 0.5% |
| legacy FRAX/USD — **do not use** | `0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD` | negative-pinned in the test suite |

## FraxLend infrastructure

| Contract | Address | Notes |
|---|---|---|
| FraxlendPairDeployer v5 | `0xF767A82a188305461b6f01a7706f7Bc0ba941ffF` | `version() = (5,0,0)`; `deploy(bytes)` whitelist-gated; must hold the asset-token seed before a deploy |
| FraxlendWhitelist | `0xDc1cf6863b6100468479fE7dd3D2D1cDe7775265` | `fraxlendDeployerWhitelist(sender)`; cross-checked against the deployer in preflight |
| FraxlendPairRegistry | `0xD6E9D27C75Afd88ad24Cd5EdccdC76fd2fc3A751` | pairs registered at deploy |
| Variable Rate V3 | `0x987a96c6637cF7E7B369BA7C1110d5fB69fb2d17` | the rate contract on every current frxUSD pair |
| Frax timelock | `0x8412ebf45bAC1B340BbE8F318b928C466c4E39CA` | governs live pairs' oracle/parameter changes |

## Reference deployments (for comparison, not consumption)

| Contract | Address | Why it matters here |
|---|---|---|
| KrwqDualOracle | `0xd84cCBd42046AA35c7d408A92872F0253aEDF030` | the live structural analogue; source of the registered `IDualOracle` id `0x415f1303`, pinned by the fork suite |
| frxUSD/KRWQ pair (#71) | `0x00C242cA3Ef5c2CB909ed3eD972B6f24624B4337` | configData baseline; this proposal deliberately tightens its live 10% oracle-deviation gate to 5% |
| wstGBP burncost aggregator (8 dp) | `0xF7493C2739c2b1bF5E6bB0e5b16A265Ed0B400B0` | sibling repo's Chainlink shim; publishes burncost only, which is why this oracle reads the token directly |
