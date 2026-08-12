-include .env

# `-include` defines make variables, not environment variables. Without `export`, the fork test
# helper and any other non-forge child would see none of it and silently fall back to defaults.
export

REQUIRED_FORGE_VERSION := 1.7.1

all         :; $(MAKE) deps && $(MAKE) build && $(MAKE) test

deps        :; forge install

build       :; forge build
clean       :; forge clean && rm -rf -- ./cache
sizes       :; forge build --sizes
fmt         :; forge fmt
fmt-check   :; forge fmt --check
lint        :; forge lint

# The release toolchain is pinned because compiler metadata and deploy artifacts are part of what
# gets reviewed. solc itself is pinned in foundry.toml; this guard pins the forge version that
# resolves it, formats the sources and produces the broadcast bundle.
check-toolchain :
	@actual="$$(forge --version | sed -n 's/^forge Version: //p')"; \
	test "$${actual}" = "$(REQUIRED_FORGE_VERSION)" || { \
		echo "forge $(REQUIRED_FORGE_VERSION) is required (got: $${actual:-unavailable})"; \
		exit 1; \
	}

# A broadcast must come from a committed tree: source verification and the independent review are
# tied to that exact commit, not to an unrecorded local diff.
clean-tree :
	@state="$$(git status --porcelain --untracked-files=all)"; \
	test -z "$${state}" || { \
		echo "the release tree is not clean:"; \
		git status --short; \
		exit 1; \
	}

# Deterministic, no-RPC checks. Keep these sequential: Foundry's build, coverage and size commands
# share out/ and cache/.
check :
	@$(MAKE) check-toolchain
	@$(MAKE) fmt-check
	@$(MAKE) build
	@$(MAKE) lint
	@$(MAKE) test
	@$(MAKE) coverage
	@$(MAKE) sizes

# Prints the immutable release identifiers that are copied into the deployment record. The
# creation-bytecode hash is pre-constructor; the deployed runtime hash is recorded from chain.
release-info : build
	@echo "commit: $$(git rev-parse HEAD)"
	@forge --version | sed -n '1p'
	@echo "solc: 0.8.34; evm: cancun; optimizer runs: 21000"
	@echo -n "oracle creation bytecode keccak: "
	@forge inspect WsgemFraxlendDualOracle bytecode | cast keccak

# Unit tests. No RPC, no network, no node. Fork tests are excluded. The redaction
# filter's own suite rides along: a silent regression there leaks provider keys into CI logs.
test        :; forge test --no-match-path "test/fork/*" -vv && python3 scripts/test_redact_rpc_stderr.py

# Fork tests. Hard-fails without a mainnet RPC rather than silently passing.
test-fork   :; ./scripts/forge_test_fork.sh

# Coverage. Fork tests stay excluded for the same reason as `test`. The report is filtered to
# src/ -- the suite and the deploy scripts are not the audited surface.
COVERAGE_EXCLUDE := (test/|script/)
COVERAGE_ARGS    := --no-match-path "test/fork/*" --no-match-coverage "$(COVERAGE_EXCLUDE)"

coverage    :; forge coverage $(COVERAGE_ARGS)

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info. Needs lcov's
# genhtml.
gen-report  :; forge coverage $(COVERAGE_ARGS) --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the report at http://localhost:8000 -- a Flatpak/Snap browser opening index.html directly
# routes through the xdg document portal, which shares only that one file with the sandbox and so
# drops the report's CSS/images.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report

# Keyless forge-script invocations (dry runs) must strip every wallet-resolving env var a previous
# deploy session may have left exported. forge binds ETH_FROM/--sender, ETH_KEYSTORE/--keystore,
# ETH_KEYSTORE_ACCOUNT/--account and ETH_PASSWORD/--password, and couples them in argument
# parsing, so a stray one turns a keyless simulation into a keystore prompt or a parse failure.
# The gas vars are stripped too: forge reads ETH_GAS_PRICE/ETH_PRIO_FEE from the environment
# directly, an empty one is a parse error, and a simulation prices nothing anyway.
KEYLESS := env -u ETH_FROM -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD \
               -u ETH_GAS_PRICE -u ETH_PRIO_FEE

# Gas overrides are optional, so they must be omitted entirely when unset rather than passed empty:
# `--priority-gas-price` with no value swallows the next flag as its argument, and forge exits.
# Both are `$(if ...)`, which expands to nothing when the variable is empty or undefined.
#
# ETH_GAS_PRICE maps to --with-gas-price, NOT --base-fee. `--base-fee` is an alias for
# `--block-base-fee-per-gas`, which sets the base fee of the SIMULATED block -- it does not price
# the broadcast transaction. `--with-gas-price` is the transaction knob (max fee per gas on an
# EIP-1559 transaction). Getting this wrong silently sends at forge's estimate instead of yours.
GAS_FLAGS := $(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
             $(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE))

# @-silencing hides the recipe TEXT, but cast and forge print the full RPC endpoint -- provider
# token included -- in their own stderr diagnostics on transport errors. Every network-touching
# forge stderr below therefore streams through this filter: failures stay descriptive, credentials
# do not survive. The `2> >(...)` process substitution needs bash.
SHELL  := /bin/bash
REDACT := python3 scripts/redact_rpc_stderr.py

# Guards for the variables a broadcast cannot proceed without. Tested as $${VAR} rather than
# $(VAR) so make does not bake the value into the recipe text, where `make -n` would print it.
define require_deploy_env
	test -n "$${ETH_RPC_URL}"        || { echo "ETH_RPC_URL is required";                  exit 1; }; \
	test -n "$${ETH_FROM}"           || { echo "ETH_FROM (deployer address) is required";  exit 1; }; \
	test -n "$${ETH_KEYSTORE}"       || { echo "ETH_KEYSTORE (keystore path) is required"; exit 1; }; \
	test -n "$${ETHERSCAN_API_KEY}"  || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
endef

# What the market broadcast needs: the deploy set MINUS the Etherscan key. The pair is created
# INSIDE FraxlendPairDeployer (CREATE2), so forge has nothing of its own to verify there.
define require_send_env
	test -n "$${ETH_RPC_URL}"  || { echo "ETH_RPC_URL is required";                  exit 1; }; \
	test -n "$${ETH_FROM}"     || { echo "ETH_FROM (sender address) is required";    exit 1; }; \
	test -n "$${ETH_KEYSTORE}" || { echo "ETH_KEYSTORE (keystore path) is required"; exit 1; }
endef

# The dry runs need only the RPC, but they need it guarded for the same reason GAS_FLAGS is: an
# empty ${ETH_RPC_URL} makes `--rpc-url` swallow the next flag as its argument.
define require_rpc
	test -n "$${ETH_RPC_URL}" || { echo "ETH_RPC_URL is required"; exit 1; }
endef

# --- Which instance ------------------------------------------------------------------------------
#
# Every deploy target below is parameterised by INSTANCE, which names the file in script/ and the
# two contracts inside it.
#
#   make configdata                             # wstGBP / frxUSD
#   make configdata INSTANCE=SomeFutureMarket   # a future wsgem market
#
# Pass it as a COMMAND-LINE assignment to make (`make configdata INSTANCE=x`), not an environment
# variable: `-include .env` + `export` makes .env values make file-variables, and file-variables
# beat environment ones.
INSTANCE ?= WstGBPFrxUSD

INSTANCE_SCRIPT = script/$(INSTANCE).s.sol
ORACLE_TARGET   = $(INSTANCE_SCRIPT):$(INSTANCE)OracleScript
MARKET_TARGET   = $(INSTANCE_SCRIPT):$(INSTANCE)MarketScript

define require_instance
	test -f "$(INSTANCE_SCRIPT)" || { \
	echo "no such instance: $(INSTANCE) (expected $(INSTANCE_SCRIPT))"; \
	echo "available:"; ls script/*.s.sol | grep -v WsgemFraxlendDeploy; \
	exit 1; }
endef

# --- Oracle ------------------------------------------------------------------------------------
#
# The oracle is deployable on its own, ahead of the pair: FraxLend pair deployment is
# whitelist-gated, so the operational order is oracle-deploy -> verify source -> hand the address
# and configdata to the Frax team (docs/instances/). The deployed address is then written back
# into the instance file's ORACLE() getter -- the market script refuses to run without it.
#
# The forge lines are @-silenced so make does not echo them into run logs, and ETH_RPC_URL is
# written $${ETH_RPC_URL} -- expanded by the shell at run time, not by make into the recipe text.
# Both defences matter separately: for most providers the URL embeds an API key, @ keeps it out
# of an ordinary run's log, and the shell-side expansion keeps it out of `make -n`.
#
# Every dry run and deploy below starts from `make clean`: forge script broadcasts whatever
# artifact sits in out/, and a stale one -- built from other source or other compiler settings --
# deploys silently. The clean ties the broadcast bytecode to the current tree.
oracle-dry  :
	@$(call require_rpc)
	@$(call require_instance)
	@make clean && make build && $(KEYLESS) forge script $(ORACLE_TARGET) \
		--rpc-url $${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

oracle-deploy :
	@$(call require_deploy_env)
	@$(call require_instance)
	make clean && make build
	@forge script $(ORACLE_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --verify --slow --broadcast -vvvv 2> >($(REDACT) >&2)

# --- Market ------------------------------------------------------------------------------------
#
# `configdata` is the expected hand-off path: it simulates the market script keylessly,
# which validates the deployed oracle against live state and prints the 288-byte configData plus a
# per-field decode table. That hex is what the Frax team feeds to their whitelisted
# FraxlendPairDeployer.deploy(). `market-dry` is the same run under the conventional name.
#
# `market-deploy` broadcasts deploy() directly and is only meaningful when ETH_FROM is on Frax's
# deployer whitelist -- the script reverts before sending otherwise.

configdata  :
	@$(call require_rpc)
	@$(call require_instance)
	@make clean && make build && $(KEYLESS) forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} -vvvv 2> >($(REDACT) >&2)

market-dry  : configdata

market-deploy :
	@$(call require_send_env)
	@$(call require_instance)
	make clean && make build
	@forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --slow --broadcast -vvvv 2> >($(REDACT) >&2)

# Resume a partial broadcast through this target. It skips clean/build because the pending
# transactions are already fixed and a rebuild cannot change them.
market-resume :
	@$(call require_send_env)
	@$(call require_instance)
	@forge script $(MARKET_TARGET) \
		--rpc-url $${ETH_RPC_URL} --sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(GAS_FLAGS) --slow --broadcast --resume -vvvv 2> >($(REDACT) >&2)

# Necessary-but-not-sufficient release gates. An independent review of the exact clean commit is
# still mandatory; see docs/deployment-runbook.md. The oracle and market stages are separate
# because ORACLE() must be zero for the first and populated for the second.
predeploy-oracle :
	@$(call require_rpc)
	@$(call require_instance)
	@$(MAKE) clean-tree
	@$(MAKE) check
	@$(MAKE) test-fork
	@$(MAKE) oracle-dry INSTANCE=$(INSTANCE)
	@$(MAKE) clean-tree
	@$(MAKE) release-info

predeploy-market :
	@$(call require_rpc)
	@$(call require_instance)
	@$(MAKE) clean-tree
	@$(MAKE) check
	@$(MAKE) test-fork
	@$(MAKE) configdata INSTANCE=$(INSTANCE)
	@$(MAKE) clean-tree
	@$(MAKE) release-info

.PHONY: all deps build clean sizes fmt fmt-check lint check-toolchain clean-tree check \
	release-info test test-fork coverage gen-report serve-report oracle-dry oracle-deploy \
	configdata market-dry market-deploy market-resume predeploy-oracle predeploy-market
