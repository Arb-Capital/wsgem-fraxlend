#!/usr/bin/env python3
"""Stream stderr while redacting credentials embedded in RPC URLs.

Two layers, because they fail differently:

1. EXACT masking of the configured endpoints. Every environment variable named `*_RPC_URL` is
   decomposed -- full URL, userinfo, query string, path segments and hostname labels of 8+
   characters -- and any occurrence of those byte strings is masked wherever it appears, URL
   context or not. This is what catches the real key regardless of length or position (QuickNode
   subdomains, short path keys, a bare hostname in a DNS-error message that never prints `://`).

2. SHAPE-based URL rewriting as a backstop for endpoints the environment never named. Any
   `://`-to-whitespace span is rewritten: basic-auth userinfo -> `***@`, token runs of 16+
   characters in the hostname or path -> `***`, the entire query string -> `?***`. Short path
   words ("reference", "forge-lint") survive so diagnostic doc links stay readable; anything long
   enough to be a key does not. A short credential in a URL that is NOT the configured endpoint
   is the residual risk this layer accepts -- layer 1 exists so that case stays hypothetical.

Only ambiguous suffixes are ever held between reads (a partial `://`, a partial secret match, an
unterminated URL), so newline-free keystore password prompts stream through live.

Self-tests: scripts/test_redact_rpc_stderr.py (table-driven, plus a chunk-boundary sweep).
"""

from __future__ import annotations

import os
import re


MARKER = b"://"
TOKEN_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
WHITESPACE_BYTES = frozenset(b" \t\r\n\v\f")
TOKEN_MIN = 16          # shape layer: shortest token run treated as a credential
COMPONENT_MIN = 8       # exact layer: shortest URL component masked stream-wide
MASK = b"***"


def secrets_from_env(environ: dict[str, str]) -> list[bytes]:
    """Byte strings worth masking, from every `*_RPC_URL` variable. Longest first, so an
    overlapping shorter component cannot pre-empt a longer match."""
    secrets: set[bytes] = set()
    for name, value in environ.items():
        if not name.endswith("_RPC_URL") or not value:
            continue
        url = value.strip().encode()
        if not url:
            continue
        secrets.add(url)

        rest = url.split(MARKER, 1)[1] if MARKER in url else url
        rest, _, query = rest.partition(b"?")
        authority, _, path = rest.partition(b"/")

        userinfo, at, host = authority.rpartition(b"@")
        if not at:
            host = authority
        components = [userinfo, query, *path.split(b"/"), *host.split(b".")]
        secrets.update(c for c in components if len(c) >= COMPONENT_MIN)

    return sorted(secrets, key=len, reverse=True)


class ExactMasker:
    """Masks every occurrence of the known secrets, holding only a suffix that could be the
    start of one."""

    def __init__(self, secrets: list[bytes]):
        self._pattern = (
            re.compile(b"|".join(re.escape(s) for s in secrets)) if secrets else None
        )
        self._max_hold = max((len(s) for s in secrets), default=1) - 1
        self._prefixes = {s[:n] for s in secrets for n in range(1, len(s))}
        self._pending = b""

    def _held_suffix_length(self, data: bytes) -> int:
        for length in range(min(len(data), self._max_hold), 0, -1):
            if data[-length:] in self._prefixes:
                return length
        return 0

    def feed(self, chunk: bytes) -> bytes:
        if self._pattern is None:
            return chunk
        data = self._pending + chunk
        held = self._held_suffix_length(data)
        data, self._pending = (data[: len(data) - held], data[len(data) - held :]) if held else (data, b"")
        return self._pattern.sub(MASK, data)

    def flush(self) -> bytes:
        if self._pattern is None or not self._pending:
            return b""
        out, self._pending = self._pattern.sub(MASK, self._pending), b""
        return out


def _mask_runs(data: bytes) -> bytes:
    """Replace every maximal run of token bytes of length >= TOKEN_MIN with ***."""
    out = bytearray()
    run: bytearray = bytearray()
    for byte in data:
        if byte in TOKEN_BYTES:
            run.append(byte)
            continue
        out += MASK if len(run) >= TOKEN_MIN else run
        run.clear()
        out.append(byte)
    out += MASK if len(run) >= TOKEN_MIN else run
    return bytes(out)


def _redact_url_tail(tail: bytes) -> bytes:
    """Redact everything after `://` up to (excluding) whitespace."""
    # Authority ends at the first '/', '?' or '#'; userinfo is anything up to the LAST '@' in it.
    authority_end = len(tail)
    for index, byte in enumerate(tail):
        if byte in b"/?#":
            authority_end = index
            break
    authority, rest = tail[:authority_end], tail[authority_end:]

    at = authority.rfind(b"@")
    if at >= 0:
        authority = MASK + b"@" + authority[at + 1 :]
    # Hostname labels are token runs between dots, so the same run masking applies: a
    # credential-bearing subdomain is long, "eth-mainnet" and friends are not.
    authority = _mask_runs(authority)

    query = rest.find(b"?")
    if query >= 0:
        rest = _mask_runs(rest[:query]) + b"?" + MASK
    else:
        rest = _mask_runs(rest)

    return MARKER + authority + rest


class UrlShapeRedactor:
    """Rewrites any URL-shaped span; holds only a partial `://` or an unterminated URL."""

    def __init__(self) -> None:
        self._pending = b""

    def _drain(self, data: bytes, *, eof: bool) -> tuple[bytes, bytes]:
        out = bytearray()
        while data:
            index = data.find(MARKER)
            if index < 0:
                if eof:
                    out += data
                    return bytes(out), b""
                held = 0
                for length in (2, 1):
                    if data[-length:] == MARKER[:length]:
                        held = length
                        break
                out += data[: len(data) - held] if held else data
                return bytes(out), data[len(data) - held :] if held else b""

            out += data[:index]
            tail = data[index + len(MARKER) :]

            # The URL runs to the next whitespace. While none has arrived the tail stays
            # ambiguous -- unless the stream is over, in which case what we have IS the URL.
            end = next((i for i, byte in enumerate(tail) if byte in WHITESPACE_BYTES), -1)
            if end < 0 and not eof:
                return bytes(out), MARKER + tail

            url, data = (tail, b"") if end < 0 else (tail[:end], tail[end:])
            out += _redact_url_tail(url)

        return bytes(out), b""

    def feed(self, chunk: bytes) -> bytes:
        out, self._pending = self._drain(self._pending + chunk, eof=False)
        return out

    def flush(self) -> bytes:
        out, self._pending = self._drain(self._pending, eof=True)
        return out


class Redactor:
    """Layer 1 (exact) feeding layer 2 (shape)."""

    def __init__(self, environ: dict[str, str]):
        self._exact = ExactMasker(secrets_from_env(environ))
        self._shape = UrlShapeRedactor()

    def feed(self, chunk: bytes) -> bytes:
        return self._shape.feed(self._exact.feed(chunk))

    def flush(self) -> bytes:
        return self._shape.feed(self._exact.flush()) + self._shape.flush()


def main() -> None:
    redactor = Redactor(dict(os.environ))

    def _write(data: bytes) -> None:
        if data:
            os.write(1, data)

    while chunk := os.read(0, 4096):
        _write(redactor.feed(chunk))
    _write(redactor.flush())


if __name__ == "__main__":
    main()
