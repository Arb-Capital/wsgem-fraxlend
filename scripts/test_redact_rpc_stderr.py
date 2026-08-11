#!/usr/bin/env python3
"""Self-tests for redact_rpc_stderr.py: a redaction table, then a chunk-boundary sweep.

Run directly (`python3 scripts/test_redact_rpc_stderr.py`); exits non-zero on any failure. Wired
into `make test` and the CI check job, because a silent regression here leaks provider keys into
CI logs -- exactly the failure the filter exists to prevent.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

_SPEC = importlib.util.spec_from_file_location(
    "redact_rpc_stderr", pathlib.Path(__file__).with_name("redact_rpc_stderr.py")
)
_MOD = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MOD)


def _run(data: bytes, environ: dict[str, str], chunk_size: int) -> bytes:
    redactor = _MOD.Redactor(environ)
    out = bytearray()
    for start in range(0, len(data), chunk_size):
        out += redactor.feed(data[start : start + chunk_size])
    out += redactor.flush()
    return bytes(out)


# (description, environ, input, substrings that MUST be gone, substrings that MUST survive)
ENV_QUICKNODE = {"ETH_RPC_URL": "https://abcdefghijklmnop.rpc.example/"}
ENV_SHORTKEY = {"ETH_RPC_URL": "https://host.example/shortkey"}
ENV_QUERY = {"ETH_RPC_URL": "https://node.example.com/rpc?apikey=sk_live_51H"}

CASES = [
    (
        "alchemy-style /v2/ key (shape layer)",
        {},
        b"error sending request for url (https://eth-mainnet.g.alchemy.com/v2/AbCdEf123456789012345678)\n",
        [b"AbCdEf123456789012345678"],
        [b"eth-mainnet.g.alchemy.com"],
    ),
    (
        "infura-style /v3/ key",
        {},
        b"https://mainnet.infura.io/v3/0123456789abcdef0123456789abcdef down\n",
        [b"0123456789abcdef0123456789abcdef"],
        [b"mainnet.infura.io"],
    ),
    (
        "quicknode-style bare path key",
        {},
        b"https://cool-name.quiknode.pro/8f2f4a1c9d3e5b7a8f2f4a1c9d3e5b7a/ timeout\n",
        [b"8f2f4a1c9d3e5b7a8f2f4a1c9d3e5b7a"],
        [b"cool-name.quiknode.pro"],
    ),
    (
        "credential-bearing subdomain label",
        {},
        b"dial https://abcdefghijklmnop.rpc.example/ refused\n",
        [b"abcdefghijklmnop"],
        [b"rpc.example"],
    ),
    (
        "query-string key",
        {},
        b"https://node.example.com/rpc?apikey=sk_live_51Habcdef&x=1 refused\n",
        [b"sk_live_51Habcdef"],
        [b"node.example.com/rpc?"],
    ),
    (
        "basic-auth userinfo",
        {},
        b"https://user:hunter2@my.node.io:8545/ dial error\n",
        [b"hunter2", b"user:"],
        [b"my.node.io:8545"],
    ),
    (
        "doc links stay readable",
        {},
        b"see https://book.getfoundry.sh/reference/forge/forge-lint#block-timestamp for help\n",
        [],
        [b"https://book.getfoundry.sh/reference/forge/forge-lint#block-timestamp"],
    ),
    (
        "URL terminated by EOF, not whitespace",
        {},
        b"tail https://x.io/v2/ZZZZZZZZZZZZZZZZZZZZ",
        [b"ZZZZZZZZZZZZZZZZZZZZ"],
        [b"x.io"],
    ),
    (
        "configured endpoint: whole URL masked wherever it appears",
        ENV_QUICKNODE,
        b"error sending request for url (https://abcdefghijklmnop.rpc.example/)\n",
        [b"abcdefghijklmnop"],
        [],
    ),
    (
        "configured endpoint: SHORT path key masked by the exact layer",
        ENV_SHORTKEY,
        b"request to https://host.example/shortkey failed\n",
        # The whole configured URL is one of the secrets, so the host goes with the key --
        # fail-closed, and the surrounding diagnosis is what must survive.
        [b"shortkey"],
        [b"request to", b"failed"],
    ),
    (
        "configured endpoint: bare hostname in a DNS error, no :// in sight",
        ENV_QUICKNODE,
        b"dns error: failed to lookup address abcdefghijklmnop.rpc.example\n",
        [b"abcdefghijklmnop"],
        [b"rpc.example"],
    ),
    (
        "configured endpoint: query fragment quoted alone",
        ENV_QUERY,
        b'bad request: "apikey=sk_live_51H"\n',
        [b"apikey=sk_live_51H"],
        [b"bad request"],
    ),
    (
        "prompts and plain text pass through byte-identical",
        ENV_QUICKNODE,
        b"Enter keystore password: \nsimulation complete, 3 transactions\n",
        [],
        [b"Enter keystore password: ", b"simulation complete, 3 transactions"],
    ),
]


def main() -> int:
    failures = 0

    for description, environ, raw, gone, kept in CASES:
        whole = _run(raw, environ, chunk_size=len(raw) or 1)
        problems = [f"leaked {secret!r}" for secret in gone if secret in whole]
        problems += [f"lost {text!r}" for text in kept if text not in whole]

        # Chunk-boundary sweep: the output must not depend on where reads split the stream.
        for chunk_size in (1, 2, 3, 7):
            chunked = _run(raw, environ, chunk_size)
            if chunked != whole:
                problems.append(f"output differs at chunk_size={chunk_size}")

        status = "FAIL" if problems else "ok"
        failures += bool(problems)
        print(f"{status:4} {description}")
        for problem in problems:
            print(f"     - {problem}")
        if problems:
            print(f"     out: {whole!r}")

    print(f"\n{len(CASES) - failures}/{len(CASES)} redaction cases passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
