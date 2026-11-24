#!/usr/bin/env bash
#
# BlueKit — install the build tools the XCFramework build needs.
#
# Everything is installed from pinned upstream source archives into $PREFIX so
# that the build does not depend on whatever a particular macOS runner image
# happens to ship. The macOS images do provide flex, ninja, pkg-config and
# Ant, which is why those are not installed here.
#
#   autoconf / automake / libtool  - regenerate the autotools build systems
#                                     of libaacs and libbdplus
#   bison                         - generate libaacs' KEYDB.cfg grammar
#                                     (macOS ships bison 2.3, which is too old)
#   meson                         - build libudfread, libxml2, freetype and
#                                     libbluray
#   pkg.m4                        - the pkg-config macro file that libaacs'
#                                     configure.ac needs
#
# Usage: scripts/install-build-tools.sh [PREFIX]
#
set -euo pipefail

PREFIX="${1:-${BLUEKIT_TOOLS_PREFIX:-/usr/local}}"
WORK_DIR="${BLUEKIT_TOOLS_WORK_DIR:-${TMPDIR:-/tmp}/bluekit-build-tools}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# name|version|url|sha256
TOOLS=(
  "m4|1.4.19|https://ftp.gnu.org/gnu/m4/m4-1.4.19.tar.xz|63aede5c6d33b6d9b13511cd0be2cac046f2e70fd0a07aa9573a04a82783af96"
  "autoconf|2.72|https://ftp.gnu.org/gnu/autoconf/autoconf-2.72.tar.xz|ba885c1319578d6c94d46e9b0dceb4014caafe2490e437a0dbca3f270a223f5a"
  "automake|1.17|https://ftp.gnu.org/gnu/automake/automake-1.17.tar.xz|8920c1fc411e13b90bf704ef9db6f29d540e76d232cb3b2c9f4dc4cc599bd990"
  "libtool|2.5.4|https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz|f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675"
  "bison|3.8.2|https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz|9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"
)

MESON_VERSION="1.12.1"

# pkgconf's macro file, needed by autoreconf for libaacs' configure.ac.
PKGCONF_VERSION="2.4.3"
PKGCONF_URL="https://distfiles.dereferenced.org/pkgconf/pkgconf-${PKGCONF_VERSION}.tar.xz"
PKGCONF_SHA256="51203d99ed573fa7344bf07ca626f10c7cc094e0846ac4aa0023bd0c83c25a41"

mkdir -p "$WORK_DIR"
mkdir -p "$PREFIX/bin"

# Always use Apple's own binutils: GNU `ar` creates archives Apple's linker
# rejects ("archive member ... is not 8-byte aligned").
TOOLCHAIN_BIN="$WORK_DIR/toolchain-bin"
mkdir -p "$TOOLCHAIN_BIN"
for t in ar ranlib nm strip ld; do
  p="$(xcrun --find "$t" 2>/dev/null || true)"
  [[ -n "$p" ]] && ln -sf "$p" "$TOOLCHAIN_BIN/$t"
done
export PATH="$TOOLCHAIN_BIN:$PATH"
export AR="$TOOLCHAIN_BIN/ar"
export RANLIB="$TOOLCHAIN_BIN/ranlib"

# The tools we install have to be visible to each other: autoconf and bison
# both need the GNU m4 that is built first.
export PATH="$PREFIX/bin:$PATH"

install_tool() {
  local name="$1" version="$2" url="$3" sha="$4"
  local archive="$WORK_DIR/${name}-${version}.tar.xz"

  if [[ ! -f "$archive" ]]; then
    log "downloading $name $version"
    curl -fsSL --retry 3 --retry-delay 2 -o "$archive.part" "$url" \
      || die "download failed: $url"
    mv "$archive.part" "$archive"
  fi

  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] || die "checksum mismatch for $name-$version: expected $sha, got $actual"

  if [[ -x "$PREFIX/bin/$name" ]]; then
    log "$name already installed"
    return
  fi

  log "building $name $version"
  local build="$WORK_DIR/build-${name}-${version}"
  rm -rf "$build"
  mkdir -p "$build"
  tar -xf "$archive" -C "$build" --strip-components=1

  ( cd "$build" && ./configure --prefix="$PREFIX" ) > "$build/configure.log" 2>&1 \
    || { tail -30 "$build/configure.log"; die "$name configure failed"; }
  ( cd "$build" && make -j"$JOBS" ) > "$build/build.log" 2>&1 \
    || { tail -30 "$build/build.log"; die "$name build failed"; }
  ( cd "$build" && make install ) > "$build/install.log" 2>&1 \
    || { tail -30 "$build/install.log"; die "$name install failed"; }
}

for entry in "${TOOLS[@]}"; do
  IFS='|' read -r name version url sha <<< "$entry"
  install_tool "$name" "$version" "$url" "$sha"
done

# meson is pure Python - install it into its own virtual environment.
if [[ ! -x "$PREFIX/bin/meson" ]]; then
  log "installing meson $MESON_VERSION"
  python3 -m venv "$PREFIX/meson-venv" || die "could not create venv for meson"
  "$PREFIX/meson-venv/bin/pip" install --quiet --upgrade pip
  "$PREFIX/meson-venv/bin/pip" install --quiet "meson==$MESON_VERSION"
  ln -sf "$PREFIX/meson-venv/bin/meson" "$PREFIX/bin/meson"
fi

# pkg.m4 - the pkg-config macros used by libaacs' configure.ac.
if [[ ! -f "$PREFIX/share/aclocal/pkg.m4" ]]; then
  log "installing pkg.m4 from pkgconf $PKGCONF_VERSION"
  archive="$WORK_DIR/pkgconf-${PKGCONF_VERSION}.tar.xz"
  if [[ ! -f "$archive" ]]; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$archive.part" "$PKGCONF_URL" \
      || die "download failed: $PKGCONF_URL"
    mv "$archive.part" "$archive"
  fi
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$PKGCONF_SHA256" ]] || die "checksum mismatch for pkgconf: expected $PKGCONF_SHA256, got $actual"
  mkdir -p "$PREFIX/share/aclocal"
  tar -xf "$archive" -C "$WORK_DIR" "pkgconf-${PKGCONF_VERSION}/pkg.m4"
  cp "$WORK_DIR/pkgconf-${PKGCONF_VERSION}/pkg.m4" "$PREFIX/share/aclocal/pkg.m4"
fi

log "installed tools in $PREFIX/bin:"
ls -1 "$PREFIX/bin" | grep -E '^(autoconf|automake|libtoolize|bison|meson)$' || true
"$PREFIX/bin/bison" --version | head -1
"$PREFIX/bin/meson" --version
