# openresty-edge

**OpenResty with HTTP/3 (QUIC), Brotli, ACME, and the CrowdSec bouncer baked in.**
A drop-in "batteries-included edge" image: TLS termination, Let's Encrypt,
WAF, compression, and HTTP/3 in one container.

[![build](https://github.com/0xFl4g/openresty-edge/actions/workflows/build.yml/badge.svg)](https://github.com/0xFl4g/openresty-edge/actions/workflows/build.yml)

```
ghcr.io/0xfl4g/openresty-edge
```

## Why this exists

The official `openresty/openresty` image is **not** compiled with
`--with-http_v3_module` and can't load `ngx_brotli` without a recompile. If you
want HTTP/3 *and* Brotli at the OpenResty layer you have to build from source
against a QUIC-capable TLS library. This image does that for you, and adds the
batteries most edge deployments end up wanting anyway:

| Component | What you get |
|-----------|--------------|
| **HTTP/3 / QUIC** | `--with-http_v3_module`, built against [quictls](https://github.com/quictls/openssl) |
| **Brotli** | [`ngx_brotli`](https://github.com/google/ngx_brotli) as a dynamic module (opt-in via `load_module`) |
| **ACME / Let's Encrypt** | [`lua-resty-acme`](https://github.com/fffonion/lua-resty-acme) (HTTP-01 + DNS-01, Redis/file storage) |
| **WAF** | [CrowdSec OpenResty bouncer](https://github.com/crowdsecurity/lua-cs-bouncer) (`require "crowdsec"`) |
| **HTTP client** | `lua-resty-http` |

Everything OpenResty normally ships (LuaJIT, `lua-resty-core`, `luarocks`,
`resty` CLI) is present. The image is **config-agnostic** — bring your own
`nginx.conf`.

## Tags

| Tag | Meaning |
|-----|---------|
| `:1.2.3` | Exact release — **pin this in production** |
| `:1.2` / `:1` | Floating minor / major |
| `:latest` | Latest release |
| `:edge` / `:edge-<sha>` | `main`-branch builds, no SLA |

Multi-arch: `linux/amd64` + `linux/arm64`.

## Usage

The image runs `openresty -g 'daemon off;'` by default. Mount your config:

```yaml
services:
  edge:
    image: ghcr.io/0xfl4g/openresty-edge:1.0.0
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"        # required for HTTP/3
    volumes:
      - ./nginx.conf:/usr/local/openresty/nginx/conf/nginx.conf:ro
      - ./conf.d:/etc/openresty/conf.d:ro
```

### Enabling Brotli

`ngx_brotli` is a **dynamic** module — load it at the top of `nginx.conf`
(main context), then enable in `http`:

```nginx
load_module modules/ngx_http_brotli_filter_module.so;
load_module modules/ngx_http_brotli_static_module.so;

http {
    brotli            on;
    brotli_comp_level 5;
    brotli_types      text/plain text/css application/json
                      application/javascript image/svg+xml;
}
```

### Enabling HTTP/3

```nginx
http {
    server {
        listen 443 quic reuseport;   # UDP — publish 443/udp
        listen 443 ssl;              # TCP fallback (h1/h2)
        http3 on;

        ssl_certificate     /path/cert.pem;
        ssl_certificate_key /path/key.pem;

        # advertise h3 to clients
        add_header Alt-Svc 'h3=":443"; ma=86400' always;
    }
}
```

### Using lua-resty-acme

`resty.acme.autossl` and its deps are on the default Lua package path (copied
into `site/lualib`), so `require("resty.acme.autossl")` works with no
`lua_package_path` changes. lua-resty-openssl FFI-loads the runtime's
`libcrypto.so.3` for cert parsing.

### Using the CrowdSec bouncer

The bouncer plugin lives at `/usr/local/openresty/lualib/plugins/crowdsec/`.
Add it to your search path and render its config:

```nginx
lua_package_path '/usr/local/openresty/lualib/plugins/crowdsec/?.lua;;';
```

A config template is at
`/etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf.template`; render it
(e.g. with `envsubst`) at container start.

## Build args

| Arg | Default | Notes |
|-----|---------|-------|
| `RESTY_VERSION` | `1.27.1.2` | OpenResty release |
| `QUICTLS_BRANCH` | `openssl-3.1.8+quic` | quictls branch (3.1.x LTS line; 3.3.0+quic fails to compile) |
| `NGX_BROTLI_REF` | pinned commit | `a71f9312…` — refresh from upstream master |
| `LUA_CS_BOUNCER_VERSION` | `v1.0.14` | CrowdSec bouncer lib |

```bash
docker build --build-arg RESTY_VERSION=1.27.1.2 -t openresty-edge:local .
```

## Notes

- **Build time**: this is a from-source OpenResty + quictls compile. CI builds
  each arch on its own native GitHub runner (amd64 + arm64, no QEMU) — ~4 min
  per arch; cached rebuilds are faster.
- **Why third-party**: there's no official OpenResty image with HTTP/3 + Brotli.
  This packages the well-trodden from-source recipe so you don't have to.

## License

MIT — see [LICENSE](./LICENSE). Bundled components keep their own licenses.
