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
ARG RESTY_VERSION=1.27.1.2
# quictls: OpenSSL fork carrying the QUIC API. Use the 3.1.x+quic LTS line —
# it's the canonical, known-to-compile branch for nginx HTTP/3 builds. The
# 3.3.0+quic branch fails to compile on modern gcc (ssl_quic.c bug) and quictls
# wound down the 3.3 line in favour of OpenSSL 3.5's native QUIC. nginx's static
# quictls and the runtime's alpine libcrypto (3.3, for lua-resty-openssl FFI)
# are independent, so the version skew is fine.
ARG QUICTLS_BRANCH=openssl-3.1.8+quic
# ngx_brotli has no recent tagged release — pin a commit for reproducible
# builds. Refresh from https://github.com/google/ngx_brotli/commits/master
ARG NGX_BROTLI_REF=master
ARG LUAROCKS_VERSION=3.11.1
# Match crowdsecurity/cs-openresty-bouncer's pinned lib version.
ARG LUA_CS_BOUNCER_VERSION=v1.0.14
ARG LUA_RESTY_HTTP_VERSION=0.17.1-0

# =============================================================================
# Stage 1 — build
# =============================================================================
FROM alpine:3.20 AS build

ARG RESTY_VERSION
ARG QUICTLS_BRANCH
ARG NGX_BROTLI_REF
ARG LUAROCKS_VERSION
ARG LUA_CS_BOUNCER_VERSION
ARG LUA_RESTY_HTTP_VERSION

RUN apk add --no-cache \
      build-base perl linux-headers \
      pcre2-dev zlib-dev brotli-dev \
      curl git bash \
      readline-dev ncurses-dev

WORKDIR /src

# --- quictls (QUIC-capable OpenSSL), built statically into nginx -------------
RUN git clone --depth 1 --branch "${QUICTLS_BRANCH}" \
      https://github.com/quictls/openssl.git quictls

# --- ngx_brotli (links against the system libbrotli from brotli-dev) ----------
# No submodule: with brotli-dev present, ngx_brotli's config links the shared
# -lbrotlienc / -lbrotlidec / -lbrotlicommon (the dynamic-module path can't use
# the bundled static brotli). brotli-libs is installed in the runtime stage so
# the .so can load.
RUN git clone https://github.com/google/ngx_brotli.git ngx_brotli \
 && git -C ngx_brotli checkout "${NGX_BROTLI_REF}"

# --- OpenResty source --------------------------------------------------------
RUN curl -fsSL "https://openresty.org/download/openresty-${RESTY_VERSION}.tar.gz" \
      | tar -xz

# --- configure + build -------------------------------------------------------
# --with-openssl builds quictls statically into nginx (gives it the QUIC API).
# --with-http_v3_module enables HTTP/3. ngx_brotli is a *dynamic* module so its
# .so lands in nginx/modules and consumers opt in via `load_module` — that keeps
# the image usable by configs that don't want brotli.
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

# --- luarocks (targeting OpenResty's bundled LuaJIT) -------------------------
RUN curl -fsSL "https://luarocks.org/releases/luarocks-${LUAROCKS_VERSION}.tar.gz" \
      | tar -xz \
 && cd "luarocks-${LUAROCKS_VERSION}" \
 && ./configure \
      --prefix=/usr/local/openresty/luajit \
      --with-lua=/usr/local/openresty/luajit \
      --lua-suffix=jit \
      --with-lua-include=/usr/local/openresty/luajit/include/luajit-2.1 \
 && make && make install

# --- baked Lua libraries -----------------------------------------------------
# lua-resty-acme pulls lua-resty-openssl + lua-resty-http as deps. All are pure
# Lua (FFI), so no C compilation — they install as .lua files.
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-http "${LUA_RESTY_HTTP_VERSION}" \
 && /usr/local/openresty/luajit/bin/luarocks install lua-resty-acme

# Make luarocks-installed rocks resolvable on OpenResty's *default* package
# path. nginx's lua_package_path does not include luajit/share/lua/5.1, but it
# does include site/lualib — so copy the rocks there. This makes the image a
# true drop-in: consumers don't have to special-case lua_package_path for
# resty.acme / resty.http / resty.openssl.
RUN mkdir -p /usr/local/openresty/site/lualib \
 && cp -R /usr/local/openresty/luajit/share/lua/5.1/. /usr/local/openresty/site/lualib/

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
FROM alpine:3.20

# Runtime libs. `openssl` provides the shared libssl.so.3 / libcrypto.so.3 that
# lua-resty-openssl FFI-loads (lua-resty-acme depends on it). nginx itself uses
# the quictls statically linked at build time for TLS/QUIC; the Lua FFI just
# needs *a* shared 3.x libcrypto for cert/key parsing. `gettext` provides
# envsubst (used to template the bouncer config at container start).
RUN apk add --no-cache \
      pcre2 zlib brotli-libs libstdc++ libgcc \
      openssl ca-certificates \
      bash curl gettext tzdata \
 && mkdir -p /var/run/openresty /var/log/openresty /etc/openresty/conf.d

COPY --from=build /usr/local/openresty /usr/local/openresty
COPY --from=build /etc/crowdsec       /etc/crowdsec
COPY --from=build /var/lib/crowdsec   /var/lib/crowdsec

ENV PATH=/usr/local/openresty/luajit/bin:/usr/local/openresty/bin:/usr/local/openresty/nginx/sbin:$PATH

# Build-time smoke test: fail the image if HTTP/3, brotli, or QUIC TLS is
# missing — turns a silently-degraded build into a hard CI failure.
RUN openresty -V 2>&1 | grep -q -- '--with-http_v3_module' \
 && openresty -V 2>&1 | grep -qi 'quic' \
 && test -f /usr/local/openresty/nginx/modules/ngx_http_brotli_filter_module.so \
 && test -f /usr/local/openresty/nginx/modules/ngx_http_brotli_static_module.so

STOPSIGNAL SIGQUIT
EXPOSE 80 443 443/udp
CMD ["openresty", "-g", "daemon off;"]
