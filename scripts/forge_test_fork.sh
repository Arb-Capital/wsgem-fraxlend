#!/usr/bin/env bash
#
# Fork tests against live mainnet state.
#
# Hard-fails without a mainnet RPC. This is deliberate: a "skip if no RPC" branch turns a missing
# RPC into a green CI run, which is exactly how a broken deploy script reaches production.
set -e

# Both cast invocations suppress stderr: on transport errors cast prints the
# full RPC URL -- provider token included -- and the message below is already
# the credential-free diagnosis.
[[ "$(cast chain --rpc-url="$ETH_RPC_URL" 2>/dev/null)" == "ethlive" ]] || {
    echo "ETH_RPC_URL must point at Ethereum mainnet (got: $(cast chain --rpc-url="$ETH_RPC_URL" 2>/dev/null || echo unreachable))"
    exit 1
}

# Pin the fork block so the RPC cache is reusable and results are reproducible. Must stay recent
# enough that the live wsgem, both Chainlink feeds, FraxlendPairDeployer v5 and the reference
# dual oracle all carry code (all true from well before 25700000).
export ETH_FORK_BLOCK="${ETH_FORK_BLOCK:-25730000}"

echo "Forking mainnet at block ${ETH_FORK_BLOCK}"

forge test --match-path "test/fork/*" -vvv "$@" \
    2> >(python3 scripts/redact_rpc_stderr.py >&2)
