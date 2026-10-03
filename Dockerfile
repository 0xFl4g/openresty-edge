# syntax=docker/dockerfile:1

# =============================================================================
# openresty-edge — OpenResty with HTTP/3 (QUIC), Brotli, ACME, and the CrowdSec
# bouncer baked in. A drop-in "batteries-included edge" image.
#
#   https://github.com/0xFl4g/openresty-edge
#   ghcr.io/0xfl4g/openresty-edge
#
# Why from source: the official openresty/openresty image is NOT compiled with
# --with-http_v3_module and cannot serve HTTP/3 or load ngx_brotli without a
# recompile. We build OpenResty against quictls (an OpenSSL fork carrying the
# QUIC API nginx HTTP/3 needs) and add ngx_brotli as a dynamic module.
#
# Config-agnostic: bring your own nginx.conf / conf.d / lua via bind mounts or
# a derived image. See README.md for enabling brotli + HTTP/3 in your config.
# =============================================================================

# ---- versions (override with --build-arg; CI pins these) --------------------
# renovate: datasource=github-tags depName=openresty/openresty extractVersion=^v(?<version>.+)$
ARG RESTY_VERSION=1.31.1.1
# sha256 of openresty-${RESTY_VERSION}.tar.gz. openresty.org publishes only a PGP
# signature (.asc, signer 25451EB0 88460026 195BD62C B550E09E A0E98066), no checksum
# file, so this was computed from the official download after verifying that
# signature. Renovate cannot update it: when bumping RESTY_VERSION, update this too
# (curl -fsSLO https://openresty.org/download/openresty-<ver>.tar.gz{,.asc}; gpg --verify; sha256sum).
ARG RESTY_SHA256=65b78baadd3f0984055de89bf13f4a1932e5bfe9c31932037a134ea2b1a0ce42
# quictls: OpenSSL fork carrying the QUIC API. Use the 3.1.x+quic LTS line —
# it's the canonical, known-to-compile branch for nginx HTTP/3 builds. The
# 3.3.0+quic branch fails to compile on modern gcc (ssl_quic.c bug) and quictls
# wound down the 3.3 line in favour of OpenSSL 3.5's native QUIC. nginx's static
# quictls and the runtime's alpine libcrypto (3.5, for lua-resty-openssl FFI)
# are independent, so the version skew is fine.
ARG QUICTLS_BRANCH=openssl-3.1.8+quic
# ngx_brotli has no recent tagged release — pinned to a commit for reproducible
# builds. Refresh from https://github.com/google/ngx_brotli/commits/master
ARG NGX_BROTLI_REF=a71f9312c2deb28875acc7bacfdd5695a111aa53
# Match crowdsecurity/cs-openresty-bouncer's pinned lib version.
# renovate: datasource=github-tags depName=crowdsecurity/lua-cs-bouncer
ARG LUA_CS_BOUNCER_VERSION=v1.0.19
# luarocks versions (X.Y.Z-<rockrev>) — no renovate datasource; refresh from
# https://luarocks.org/modules/fffonion
ARG LUA_RESTY_HTTP_VERSION=0.17.1-0
ARG LUA_RESTY_ACME_VERSION=0.16.0-1

# =============================================================================
# Stage 1 — build
# =============================================================================
FROM alpine:3.24 AS build

ARG RESTY_VERSION
ARG RESTY_SHA256
ARG QUICTLS_BRANCH
ARG NGX_BROTLI_REF
ARG LUA_CS_BOUNCER_VERSION
ARG LUA_RESTY_HTTP_VERSION
ARG LUA_RESTY_ACME_VERSION

# hadolint ignore=DL3018 # apk pins would break on every alpine patch; the base tag is the pin
RUN apk add --no-cache \
      build-base perl linux-headers \
      pcre2-dev zlib-dev brotli-dev \
      curl wget git bash ca-certificates \
      readline-dev ncurses-dev \
      luarocks5.1 lua5.1

WORKDIR /src

# --- quictls (QUIC-capable OpenSSL), built statically into nginx -------------
RUN git clone --depth 1 --branch "${QUICTLS_BRANCH}" \
      https://github.com/quictls/openssl.git quictls

# --- ngx_brotli -------------------------------------------------------------
# Needs BOTH: the bundled submodule (ngx_brotli's config hard-requires
# deps/brotli/c or it errors) AND the system brotli-dev (the *dynamic* module's
# link line references shared -lbrotlienc/-lbrotlidec/-lbrotlicommon regardless
# of the bundled sources). brotli-libs is installed in the runtime stage so the
# .so can load. Pin NGX_BROTLI_REF to a commit for reproducible releases.
RUN git clone --recurse-submodules --shallow-submodules \
      https://github.com/google/ngx_brotli.git ngx_brotli \
 && git -C ngx_brotli checkout "${NGX_BROTLI_REF}" \
 && git -C ngx_brotli submodule update --init --recursive

# --- OpenResty source --------------------------------------------------------
RUN curl -fsSLo openresty.tar.gz "https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz" \
 && echo "${RESTY_SHA256}  openresty.tar.gz" > openresty.tar.gz.sha256 \
 && sha256sum -c openresty.tar.gz.sha256 \
 && tar -xzf openresty.tar.gz \
 && rm openresty.tar.gz openresty.tar.gz.sha256

# --- nginx security backports ------------------------------------------------
# OpenResty 1.31.1.1 bundles nginx 1.31.1, which predates the fixes for
# CVE-2026-42530/42055/48142 (nginx 1.31.2) and CVE-2026-42533/60005/56434
# (nginx 1.31.3). Each patches/nginx/*.patch names its upstream commits. A patch
# that doesn't apply fails the build; the hardcoded nginx-1.31.1 path also fails
# on an OpenResty bump, which is the cue to drop patches the new nginx contains.
COPY patches/nginx/ /src/patches/nginx/
RUN for p in /src/patches/nginx/*.patch; do \
      echo "applying ${p}"; \
      patch -d "openresty-${RESTY_VERSION}/bundle/nginx-1.31.1" -p1 --forward < "${p}" || exit 1; \
    done

# --- configure + build -------------------------------------------------------
# --with-openssl builds quictls statically into nginx (gives it the QUIC API).
# --with-http_v3_module enables HTTP/3. ngx_brotli is a *dynamic* module so its
# .so lands in nginx/modules and consumers opt in via `load_module` — that keeps
# the image usable by configs that don't want brotli.
# hadolint ignore=DL3003 # one-shot configure+make chain
RUN cd "openresty-${RESTY_VERSION}" \
 && ./configure \
      --prefix=/usr/local/openresty \
      --with-pcre-jit \
      --with-threads \
      --with-compat \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_v3_module \
      --with-http_realip_module \
      --with-http_stub_status_module \
      --with-http_gunzip_module \
      --with-luajit \
      --with-openssl=/src/quictls \
      --with-openssl-opt='no-tests' \
      --add-dynamic-module=/src/ngx_brotli \
      -j"$(nproc)" \
 && make -j"$(nproc)" \
 && make install

ENV PATH=/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:$PATH

# --- baked Lua libraries -----------------------------------------------------
# Resolved with alpine's PUC-Rio luarocks (luarocks-5.1), NOT a LuaJIT-built
# luarocks: the luarocks.org manifest is too large for LuaJIT to parse ("main
# function has more than 65536 constants"). PUC Lua 5.1 loads it fine. The rocks
# are pure Lua (lua-resty-acme + its deps lua-resty-http + lua-resty-openssl, the
# latter FFI-loads libcrypto at runtime), so the interpreter that *installs* them
# is irrelevant — only the .lua files matter.
#
# Install into a throwaway tree, then copy the modules into site/lualib so they
# resolve on OpenResty's default lua_package_path (a true drop-in: consumers
# don't special-case lua_package_path for resty.acme/http/openssl). lua-resty-http
# is pinned to match the version the CrowdSec bouncer expects.
RUN luarocks-5.1 install --tree /tmp/rocks lua-resty-http "${LUA_RESTY_HTTP_VERSION}" \
 && luarocks-5.1 install --tree /tmp/rocks lua-resty-acme "${LUA_RESTY_ACME_VERSION}" \
 && mkdir -p /usr/local/openresty/site/lualib \
 && cp -R /tmp/rocks/share/lua/5.1/. /usr/local/openresty/site/lualib/ \
 && rm -rf /tmp/rocks

# CrowdSec OpenResty bouncer (Lua sources live in crowdsecurity/lua-cs-bouncer;
# cs-openresty-bouncer is a thin wrapper image — we replicate its install).
# `require "crowdsec"` resolves from lualib/plugins/crowdsec/ — consumers add
# that dir to lua_package_path (see README).
RUN git clone --depth 1 --branch "${LUA_CS_BOUNCER_VERSION}" \
        https://github.com/crowdsecurity/lua-cs-bouncer.git /tmp/lua-cs-bouncer \
 && mkdir -p /etc/crowdsec/bouncers/ /var/lib/crowdsec/lua/templates/ \
 && cp -R /tmp/lua-cs-bouncer/lib/* /usr/local/openresty/lualib/ \
 && cp -R /tmp/lua-cs-bouncer/templates/* /var/lib/crowdsec/lua/templates/ \
 && cp /tmp/lua-cs-bouncer/config_example.conf \
        /etc/crowdsec/bouncers/crowdsec-openresty-bouncer.conf.template \
 && rm -rf /tmp/lua-cs-bouncer

# =============================================================================
# Stage 2 — runtime
# =============================================================================
FROM alpine:3.24

# Runtime libs. `openssl` provides the shared libssl.so.3 / libcrypto.so.3 that
# lua-resty-openssl FFI-loads (lua-resty-acme depends on it). nginx itself uses
# the quictls statically linked at build time for TLS/QUIC; the Lua FFI just
# needs *a* shared 3.x libcrypto for cert/key parsing. `gettext` provides
# envsubst (used to template the bouncer config at container start).
# hadolint ignore=DL3018 # see build stage
RUN apk add --no-cache \
      pcre2 zlib brotli-libs libstdc++ libgcc \
      openssl ca-certificates \
      bash curl gettext tzdata perl \
 && mkdir -p /var/run/openresty /var/log/openresty /etc/openresty/conf.d

COPY --from=build /usr/local/openresty /usr/local/openresty
COPY --from=build /etc/crowdsec       /etc/crowdsec
COPY --from=build /var/lib/crowdsec   /var/lib/crowdsec

ENV PATH=/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:$PATH

# Build-time smoke test: fail the image if HTTP/3 (nginx's configure only
# accepts the v3 module when the TLS library has the QUIC API) or brotli is
# missing — turns a silently-degraded build into a hard CI failure.
# hadolint ignore=DL4006 # grep exit status is the test
RUN openresty -V 2>&1 | grep -q -- '--with-http_v3_module' \
 && test -f /usr/local/openresty/nginx/modules/ngx_http_brotli_filter_module.so \
 && test -f /usr/local/openresty/nginx/modules/ngx_http_brotli_static_module.so

STOPSIGNAL SIGQUIT
EXPOSE 80 443 443/udp
CMD ["openresty", "-g", "daemon off;"]
