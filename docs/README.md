# libflux Documentation

## What this package does

`libflux` implements HTTP/3 and WebTransport behavior over QUIC.

Primary areas include:

- HTTP/3 frame parsing/encoding
- control stream handling and settings
- QPACK state and control synchronization
- WebTransport stream/session handling
- protocol-level negative and parity-oriented tests

## Design focus

`libflux` targets web/TLS-style QUIC application semantics.

It is centered on protocol correctness and predictable framing behavior, with translated parity checks from reference behavior where applicable.

## Main library areas

- `lib/h3_framing.zig`
  - HTTP/3 frame encode/decode logic
- `lib/h3_control_reader.zig`
  - control stream parsing and validation
- `lib/qpack.zig`
  - QPACK behavior and synchronization logic
- `lib/wt_core.zig`
  - WebTransport core structures and state helpers
- `lib/interop_scenarios.zig`
  - interop status checks and scenario glue
- `lib/negative_corpus.zig`
  - malformed input and rejection tests

## Typical usage model

1. Initialize transport-facing context.
2. Establish HTTP/3 control stream semantics.
3. Process request/response framing via H3 frame utilities.
4. Enable WebTransport sessions/streams where needed.
5. Validate behavior with parity and negative test suites.

## Build and test

```bash
make build
make test
```

## Version

- `0.0.5`
