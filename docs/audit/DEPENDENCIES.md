# Frontend dependency review — September 5, 2026

A clean npm install exposed differences from the pre-existing pnpm-installed
tree. The release now uses the committed npm lockfile and a fresh `npm ci`.
Patch overrides pin axios 1.18.0, ws 8.21.0 (the older JSON-RPC adapter keeps the
patched 7.5.13 line), and uuid 11.1.1. UUID retains both CommonJS and ESM exports;
the CommonJS interface, frontend ABI/transaction tests, TypeScript and Vite build
were checked after installation. The wallet dialog receives browser checking.

The final npm advisory scan reports **0 critical, 0 high, 16 moderate** entries.
The sixteen entries propagate one underlying advisory through the WalletConnect
dependency graph: the older CommonJS `decode-uri-component` decoder can spend
excessive CPU on malformed escaped input. Its patched release is ESM-only; blindly
overriding that package would break its CommonJS caller. A compatible upstream
wallet-stack migration remains follow-up work before a mainnet release. This is
a recorded residual risk, not an assertion that every flagged package contains
an independent exploit or that the vulnerable path is unreachable in this app.

Primary advisory records:

- [ws fragment-memory exhaustion](https://github.com/websockets/ws/security/advisories/GHSA-96hv-2xvq-fx4p)
- [uuid buffer bounds](https://github.com/uuidjs/uuid/security/advisories/GHSA-w5hq-g745-h8pq)
- [decode-uri-component malformed-input denial of service](https://github.com/advisories/GHSA-vcc3-ghjq-m6fr)

The host's pre-existing global npm installation fails before executing commands.
An isolated official npm 10.9.8 tarball, checked against its registry SHA-512
integrity, performed the clean install. No global npm installation was modified.
The running preview and direct deterministic gate do not depend on that global
npm command. npm advisory scanning is a separate network gate; it is not a
deterministic contract-security test.
