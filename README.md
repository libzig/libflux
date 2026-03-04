# libflux

HTTP/3 + WebTransport package in Zig.

## Overview

`libflux` focuses on the web/TLS side of QUIC systems.

- HTTP/3 framing and control stream handling
- QPACK behavior and control synchronization
- WebTransport streams and session handling
- Parity-oriented tests translated from reference implementations

In short: if your product needs HTTP/3 or WebTransport semantics over QUIC, this is the package.

## Build and Test

```bash
make build
make test
```

## Docs

- See `docs/` for package documentation and notes.
- If `docs/` is currently sparse, it is the canonical place for upcoming docs.

## Acknowledgments

- See `ACKNOWLEDGMENTS.md`.

## Version

- Current package version: `0.0.5`
