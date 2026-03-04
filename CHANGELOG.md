# Changelog

## [0.0.6] - 2026-03-04

### <!-- 3 -->📚 Documentation

- Add initial documentation files

### <!-- 7 -->⚙️ Miscellaneous Tasks

- Update libfast dependency

## [0.0.5] - 2026-03-04

### <!-- 0 -->⛰️  Features

- Update libfast dependency to 0.0.14

## [0.0.3] - 2026-03-03

### <!-- 0 -->⛰️  Features

- Add wt stream reset stop-sending and partial writes
- Add wt datagram backpressure and late-drop handling
- Add webtransport stream association handling
- Add webtransport session lifecycle registry
- Add webtransport settings parsing and enforcement
- Add webtransport capsule encoder and decoder
- Add webtransport datagram session routing
- Add webtransport settings negotiation gates
- Add qpack dynamic table and unblock handling
- Add qpack control stream sync and partial write handling
- Add static-only qpack header encode decode
- Add basic in-memory h3 request response api
- Add h3 transaction state machine
- Add h3 headers/data framing codec
- Add h3 control stream writer
- Implement h3 control stream reader with settings rules
- Add h3 stream role registry and constants
- Enforce h3 ALPN readiness gate
- Implement transport adapter with fake harness
- Scaffold core modules and parity inventory
- Init

### <!-- 6 -->🧪 Testing

- Co-locate parity tests in modules and drop tests dir
- Translate lsquic parity vectors into zig suites
- Add interop scenario suite and scriptable live target
- Add negative corpus and fuzz smoke coverage
- Add lsquic parity matrix coverage checks

