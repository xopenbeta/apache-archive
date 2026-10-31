#!/usr/bin/env bash
#
# Build a relocatable Apache httpd package for macOS or Linux.
#
#   scripts/build-unix.sh <macos|linux> <arm64|x86_64>
#
# All dependencies are compiled from source and linked statically, so the
# resulting package does not depend on Homebrew or distribution libraries.
#
# Version pins are read from the environment (the GitHub Actions workflow
# passes them in) and fall back to the versions below for local runs.

set -euo pipefail

PLATFORM="${1:-}"
ARCH="${2:-}"

usage() {
    echo "usage: $0 <macos|linux> <arm64|x86_64>" >&2
    exit 2
}

case "$PLATFORM" in
    macos|linux) ;;
    *) usage ;;
esac
case "$ARCH" in
    arm64|x86_64) ;;
    *) usage ;;
esac

HTTPD_VERSION="${HTTPD_VERSION:-2.4.69}"
APR_VERSION="${APR_VERSION:-1.7.6}"
APR_UTIL_VERSION="${APR_UTIL_VERSION:-1.6.5}"
PCRE2_VERSION="${PCRE2_VERSION:-10.48}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.9}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
EXPAT_VERSION="${EXPAT_VERSION:-2.9.0}"
NGHTTP2_VERSION="${NGHTTP2_VERSION:-1.70.0}"

HTTPD_PORT="${HTTPD_PORT:-8080}"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-12.0}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/work}"
DEPS="${DEPS:-$ROOT/deps}"
STAGE="${STAGE:-$ROOT/stage}"

INSTALL_DIR="httpd-${HTTPD_VERSION}-${PLATFORM}-${ARCH}"
PKG_ROOT="$STAGE/$INSTALL_DIR"
PKG="$ROOT/$INSTALL_DIR.tar.gz"

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

export LC_ALL=C

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

fetch() {
    local url="$1"
    local out="$2"
    if [ -s "$WORK/$out" ]; then
        return
    fi
    log "download $out"
    curl -fSL --retry 3 --retry-delay 2 --connect-timeout 30 \
        -o "$WORK/$out.part" "$url" || die "failed to download $url"
    mv "$WORK/$out.part" "$WORK/$out"
}

fetch_apache() {
    local rel="$1"
    local out="$2"
    if [ -s "$WORK/$out" ]; then
        return
    fi
    log "download $out"
    if ! curl -fSL --retry 3 --retry-delay 2 --connect-timeout 30 \
        -o "$WORK/$out.part" "https://dlcdn.apache.org/$rel"; then
        log "dlcdn mirror failed, falling back to archive.apache.org"
        curl -fSL --retry 3 --retry-delay 2 --connect-timeout 30 \
            -o "$WORK/$out.part" "https://archive.apache.org/dist/$rel" \
            || die "failed to download $rel"
    fi
    mv "$WORK/$out.part" "$WORK/$out"
}

untar() {
    local archive="$1"
    local dir="$2"
    if [ ! -d "$WORK/$dir" ]; then
        log "extract $archive"
        tar -xzf "$WORK/$archive" -C "$WORK"
    fi
}

configure_platform() {
    if [ "$PLATFORM" = "macos" ]; then
        export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
        CFLAGS="-O2 -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET} -arch ${ARCH}"
        LDFLAGS="-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET} -arch ${ARCH}"
        OPENSSL_TARGET="darwin64-${ARCH}-cc"
        # The darwin64 target already supplies -arch; passing it separately
        # makes Configure treat the arch name as a second target.
        OPENSSL_EXTRA_FLAGS="-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"
        # arm64 binaries are ad-hoc signed by the linker; stripping would
        # invalidate that signature.
        STRIP_CMD=""
    else
        CFLAGS="-O2 -fPIC"
        LDFLAGS=""
        if [ "$ARCH" = "x86_64" ]; then
            OPENSSL_TARGET="linux-x86_64"
        else
            OPENSSL_TARGET="linux-aarch64"
        fi
        OPENSSL_EXTRA_FLAGS="-fPIC"
        STRIP_CMD="strip --strip-unneeded"
    fi
    export CFLAGS
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS
}

fetch_sources() {
    mkdir -p "$WORK" "$DEPS"
    fetch_apache "httpd/httpd-${HTTPD_VERSION}.tar.gz" \
        "httpd-${HTTPD_VERSION}.tar.gz"
    fetch_apache "apr/apr-${APR_VERSION}.tar.gz" \
        "apr-${APR_VERSION}.tar.gz"
    fetch_apache "apr/apr-util-${APR_UTIL_VERSION}.tar.gz" \
        "apr-util-${APR_UTIL_VERSION}.tar.gz"
    fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" \
        "pcre2-${PCRE2_VERSION}.tar.gz"
    fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
        "openssl-${OPENSSL_VERSION}.tar.gz"
    fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        "zlib-${ZLIB_VERSION}.tar.gz"
    fetch "https://github.com/libexpat/libexpat/releases/download/R_$(printf '%s' "$EXPAT_VERSION" | tr '.' '_')/expat-${EXPAT_VERSION}.tar.gz" \
        "expat-${EXPAT_VERSION}.tar.gz"
    fetch "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.gz" \
        "nghttp2-${NGHTTP2_VERSION}.tar.gz"
}

build_zlib() {
    untar "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"
    log "build zlib ${ZLIB_VERSION}"
    (
        cd "$WORK/zlib-${ZLIB_VERSION}"
        CFLAGS="$CFLAGS" ./configure --prefix="$DEPS"
        make -j"$JOBS"
        make install
        # Force static linking: zlib installs a shared library as well.
        rm -f "$DEPS"/lib/libz.so* "$DEPS"/lib/libz.*dylib
    )
}

build_openssl() {
    untar "openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}"
    log "build OpenSSL ${OPENSSL_VERSION} (${OPENSSL_TARGET})"
    (
        cd "$WORK/openssl-${OPENSSL_VERSION}"
        # shellcheck disable=SC2086
        perl ./Configure "$OPENSSL_TARGET" \
            --prefix="$DEPS" \
            --libdir="$DEPS/lib" \
            --openssldir=/etc/ssl \
            no-shared no-tests \
            $OPENSSL_EXTRA_FLAGS
        make -j"$JOBS"
        make install_sw
    )
}

build_expat() {
    untar "expat-${EXPAT_VERSION}.tar.gz" "expat-${EXPAT_VERSION}"
    local src="$WORK/expat-${EXPAT_VERSION}"
    if [ ! -x "$src/configure" ] && [ -x "$src/expat/configure" ]; then
        src="$src/expat"
    fi
    log "build Expat ${EXPAT_VERSION}"
    (
        cd "$src"
        CFLAGS="$CFLAGS" ./configure --prefix="$DEPS" \
            --disable-shared --enable-static \
            --without-xmlwf --without-docbook --without-examples --without-tests
        make -j"$JOBS"
        make install
    )
}

build_pcre2() {
    untar "pcre2-${PCRE2_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}"
    log "build PCRE2 ${PCRE2_VERSION}"
    (
        cd "$WORK/pcre2-${PCRE2_VERSION}"
        CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" ./configure \
            --prefix="$DEPS" \
            --disable-shared --enable-static \
            --enable-pcre2-8 --enable-unicode
        make -j"$JOBS"
        make install
    )
}

build_nghttp2() {
    untar "nghttp2-${NGHTTP2_VERSION}.tar.gz" "nghttp2-${NGHTTP2_VERSION}"
    log "build nghttp2 ${NGHTTP2_VERSION}"
    (
        cd "$WORK/nghttp2-${NGHTTP2_VERSION}"
        CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" ./configure \
            --prefix="$DEPS" \
            --disable-shared --enable-static \
            --enable-lib-only
        make -j"$JOBS"
        make install
    )
}

build_apr() {
    untar "apr-${APR_VERSION}.tar.gz" "apr-${APR_VERSION}"
    log "build APR ${APR_VERSION}"
    (
        cd "$WORK/apr-${APR_VERSION}"
        CFLAGS="$CFLAGS" ./configure --prefix="$DEPS" \
            --disable-shared --enable-static
        make -j"$JOBS"
        make install
    )
}

build_apr_util() {
    untar "apr-util-${APR_UTIL_VERSION}.tar.gz" "apr-util-${APR_UTIL_VERSION}"
    log "build APR-util ${APR_UTIL_VERSION}"
    (
        cd "$WORK/apr-util-${APR_UTIL_VERSION}"
        CFLAGS="$CFLAGS" \
        CPPFLAGS="-I$DEPS/include" \
        LDFLAGS="-L$DEPS/lib" \
            ./configure --prefix="$DEPS" \
                --with-apr="$DEPS/bin/apr-1-config" \
                --with-expat="$DEPS" \
                --disable-shared --enable-static \
                --without-ldap \
                --without-sqlite3 --without-mysql --without-pgsql --without-oracle --without-odbc \
                --without-gdbm --without-ndbm --without-berkeley-db
        make -j"$JOBS"
        make install
    )
}

build_httpd() {
    untar "httpd-${HTTPD_VERSION}.tar.gz" "httpd-${HTTPD_VERSION}"
    log "configure httpd ${HTTPD_VERSION}"

    (
        cd "$WORK/httpd-${HTTPD_VERSION}"

        PKG_CONFIG_PATH="$DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
        CFLAGS="$CFLAGS" \
        LDFLAGS="$LDFLAGS" \
            ./configure \
                --prefix="/${INSTALL_DIR}" \
                --with-apr="$DEPS" \
                --with-apr-util="$DEPS" \
                --with-pcre="$DEPS/bin/pcre2-config" \
                --with-ssl="$DEPS" \
                --with-z="$DEPS" \
                --with-nghttp2="$DEPS" \
                --enable-mods-static=most \
                --enable-ssl=static \
                --enable-http2=static \
                --enable-proxy-http2=static \
                --with-mpm=event \
                --with-port="$HTTPD_PORT"

        log "build httpd ${HTTPD_VERSION}"
        make -j"$JOBS"
    )
}

strip_package() {
    local f
    [ -n "$STRIP_CMD" ] || return 0
    for f in "$PKG_ROOT"/bin/*; do
        [ -f "$f" ] || continue
        case "$(file -b "$f" 2>/dev/null || true)" in
            *Mach-O*|*ELF*) $STRIP_CMD "$f" 2>/dev/null || true ;;
        esac
    done
}

copy_if_exists() {
    if [ -f "$1" ]; then
        cp "$1" "$2"
    fi
}

install_licenses() {
    local dst="$PKG_ROOT/licenses"
    mkdir -p "$dst"
    copy_if_exists "$WORK/httpd-${HTTPD_VERSION}/LICENSE" "$dst/LICENSE-httpd.txt"
    copy_if_exists "$WORK/httpd-${HTTPD_VERSION}/NOTICE" "$dst/NOTICE-httpd.txt"
    copy_if_exists "$WORK/apr-${APR_VERSION}/LICENSE" "$dst/LICENSE-apr.txt"
    copy_if_exists "$WORK/apr-util-${APR_UTIL_VERSION}/LICENSE" "$dst/LICENSE-apr-util.txt"
    copy_if_exists "$WORK/pcre2-${PCRE2_VERSION}/LICENCE" "$dst/LICENSE-pcre2.txt"
    copy_if_exists "$WORK/openssl-${OPENSSL_VERSION}/LICENSE.txt" "$dst/LICENSE-openssl.txt"
    copy_if_exists "$WORK/zlib-${ZLIB_VERSION}/LICENSE" "$dst/LICENSE-zlib.txt"
    copy_if_exists "$WORK/expat-${EXPAT_VERSION}/COPYING" "$dst/LICENSE-expat.txt"
    copy_if_exists "$WORK/nghttp2-${NGHTTP2_VERSION}/COPYING" "$dst/LICENSE-nghttp2.txt"
}

rewrite_conf() {
    local f has_shared_modules
    has_shared_modules=0
    for f in "$PKG_ROOT"/modules/*.so; do
        if [ -f "$f" ]; then
            has_shared_modules=1
            break
        fi
    done

    find "$PKG_ROOT/conf" -type f -name '*.conf' -print | while IFS= read -r f; do
        sed -i.bak \
            -e "s|/${INSTALL_DIR}|\${SRVROOT}|g" \
            -e '/^[[:space:]]*Define[[:space:]][[:space:]]*SRVROOT/d' \
            "$f"
        # A static build must not try to load the modules it embeds.
        if [ "$has_shared_modules" -eq 0 ]; then
            sed -i.bak -e '/^[[:space:]]*LoadModule/d' "$f"
        fi
        rm -f "$f.bak"
    done

    if ! grep -q '^ServerRoot' "$PKG_ROOT/conf/httpd.conf"; then
        local tmp="$PKG_ROOT/conf/httpd.conf.tmp"
        {
            printf 'ServerRoot "${SRVROOT}"\n'
            cat "$PKG_ROOT/conf/httpd.conf"
        } > "$tmp"
        mv "$tmp" "$PKG_ROOT/conf/httpd.conf"
    fi
}

install_launcher() {
    cat > "$PKG_ROOT/bin/apachectl" <<'LAUNCHER'
#!/bin/sh
# Relocatable launcher generated by apache-archive.
SELF=$0
case "$SELF" in
    */*) ;;
    *) SELF=$(command -v "$SELF" 2>/dev/null || printf '%s' "$SELF") ;;
esac
ROOT=$(CDPATH= cd "$(dirname "$SELF")/.." && pwd) || exit 1
HTTPD="$ROOT/bin/httpd"
if [ ! -x "$HTTPD" ]; then
    echo "apachectl: cannot find $HTTPD" >&2
    exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
    exec "$HTTPD" -d "$ROOT" -C "Define SRVROOT \"$ROOT\"" -f "$ROOT/conf/httpd.conf" "$@"
else
    # The stock configuration runs as "daemon", which cannot traverse a
    # package extracted into a private home directory. When started as a
    # normal user, keep the server under that user instead.
    exec "$HTTPD" -d "$ROOT" -C "Define SRVROOT \"$ROOT\"" -f "$ROOT/conf/httpd.conf" \
        -c "User #$(id -u)" -c "Group #$(id -g)" "$@"
fi
LAUNCHER
    chmod 755 "$PKG_ROOT/bin/apachectl"
}

package() {
    log "install httpd into $STAGE"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    (
        cd "$WORK/httpd-${HTTPD_VERSION}"
        make install DESTDIR="$STAGE"
    )

    strip_package
    install_licenses
    rewrite_conf
    install_launcher
    mkdir -p "$PKG_ROOT/logs"

    log "create $INSTALL_DIR.tar.gz"
    (
        cd "$STAGE"
        tar -czf "$PKG" "$INSTALL_DIR"
    )

    if [ "$PLATFORM" = "macos" ]; then
        ( cd "$ROOT" && shasum -a 256 "$INSTALL_DIR.tar.gz" > "$INSTALL_DIR.tar.gz.sha256" )
    else
        ( cd "$ROOT" && sha256sum "$INSTALL_DIR.tar.gz" > "$INSTALL_DIR.tar.gz.sha256" )
    fi
}

verify() {
    local tmp pkg ok i mods
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/httpd-verify.XXXXXX")"
    log "verify $INSTALL_DIR"

    tar -xzf "$PKG" -C "$tmp"
    pkg="$tmp/$INSTALL_DIR"

    local version
    version="$("$pkg/bin/httpd" -v 2>&1 || true)"
    printf '%s\n' "$version" | grep -q "Apache/${HTTPD_VERSION}" \
        || die "unexpected version output: $version"

    "$pkg/bin/apachectl" -t || die "configuration test failed"

    grep -Fq 'ServerRoot "${SRVROOT}"' "$pkg/conf/httpd.conf" \
        || die "conf/httpd.conf was not made relocatable"
    if grep -Fq "$STAGE/$INSTALL_DIR" "$pkg/conf/httpd.conf"; then
        die "conf/httpd.conf still contains the staging path"
    fi

    "$pkg/bin/apachectl" -k start || die "httpd failed to start"

    ok=0
    for i in $(seq 1 30); do
        if curl -fsS --noproxy '*' --max-time 2 "http://127.0.0.1:${HTTPD_PORT}/" -o "$tmp/index.html" 2>/dev/null; then
            ok=1
            break
        fi
        sleep 1
    done

    "$pkg/bin/apachectl" -k stop >/dev/null 2>&1 || true

    if [ "$ok" -ne 1 ]; then
        for i in "$pkg/logs/error_log" "$pkg/logs/error.log"; do
            if [ -f "$i" ]; then
                tail -n 40 "$i" >&2 || true
            fi
        done
        rm -rf "$tmp"
        die "httpd did not answer on port ${HTTPD_PORT}"
    fi

    grep -q "It works!" "$tmp/index.html" \
        || die "unexpected DocumentRoot response in $tmp/index.html"

    mods="$("$pkg/bin/apachectl" -M 2>&1 || true)"
    for i in ssl_module http2_module proxy_http2_module rewrite_module mpm_event_module; do
        printf '%s\n' "$mods" | grep -q "$i" \
            || die "module $i is missing from httpd -M"
    done

    case "$PLATFORM" in
        macos)
            if otool -L "$pkg/bin/httpd" | grep -Eq '/(opt/homebrew|usr/local/opt|nix/store)/'; then
                otool -L "$pkg/bin/httpd" >&2
                rm -rf "$tmp"
                die "httpd still depends on build-host libraries"
            fi
            ;;
        linux)
            if ldd "$pkg/bin/httpd" | grep -Eq '/(opt/homebrew|usr/local/opt|nix/store)/'; then
                ldd "$pkg/bin/httpd" >&2
                rm -rf "$tmp"
                die "httpd still depends on build-host libraries"
            fi
            ;;
    esac

    rm -rf "$tmp"
    log "verification passed"
}

main() {
    configure_platform
    fetch_sources

    build_zlib
    build_openssl
    build_expat
    build_pcre2
    build_nghttp2
    build_apr
    build_apr_util
    build_httpd

    package
    verify

    log "done: $PKG"
}

main "$@"
