# openresty-edge

Docker image: OpenResty built from source with HTTP/3 (quictls), Brotli
(dynamic module), lua-resty-acme, and the CrowdSec bouncer. Published to
`ghcr.io/0xfl4g/openresty-edge`. No app code — just `Dockerfile`, two
workflows, and `examples/`.

## Verifying changes

Any Dockerfile change: build locally and run the same checks as
`.github/workflows/test.yml` (V-string has `--with-http_v3_module` + quic,
brotli `.so`s exist, `resty -e 'require(...)'` for the baked Lua libs,
`openresty -t` with the example config). Local builds are arm64 (Apple
Silicon); CI's test workflow covers amd64. A clean build already proves a
lot — the Dockerfile has a built-in smoke test stage that fails the image
if HTTP/3/QUIC/brotli are missing.

## Version pins — what updates how

- `RESTY_VERSION`, `LUA_CS_BOUNCER_VERSION`, base `alpine` images:
  Renovate-tracked (regex manager reads the `# renovate:` ARG comments).
- `QUICTLS_BRANCH`: manual, stay on the 3.1.x+quic LTS line — 3.3.0+quic
  does not compile (see Dockerfile comment). Revisit only for OpenSSL 3.5
  native QUIC migration.
- `NGX_BROTLI_REF`: manual commit pin — upstream doesn't tag releases.
- `LUA_RESTY_HTTP_VERSION` / `LUA_RESTY_ACME_VERSION`: luarocks rock
  versions (`X.Y.Z-rev`), no Renovate datasource — refresh manually from
  luarocks.org. lua-resty-http must match what the CrowdSec bouncer expects.
- Watch alpine EOL (~2 years per release); Renovate proposes bumps but the
  risky bit is libcrypto major changes hitting the lua-resty-openssl FFI —
  verify `require("resty.openssl.x509")` after any bump.

## Releases

- Push to `main` → `:edge`, `:edge-<sha>` (build.yml, paths-filtered to
  Dockerfile/workflow).
- Tag `vX.Y.Z` → `:X.Y.Z`, `:X.Y`, `:X`, `:latest`.
- Each arch builds on its own native runner; no QEMU. test.yml shares the
  `linux-amd64` GHA cache scope with build.yml — keep them in sync.
