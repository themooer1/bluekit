#!/usr/bin/env bash
#
# BlueKit — build script for the macOS XCFramework distribution.
#
# Builds libbluray, libaacs and libbdplus (plus their permissive transitive
# dependencies) from pinned upstream source tarballs for both arm64 and
# x86_64, then packages each dynamic library into an .xcframework.
#
# Outputs (in ./dist):
#   LibBluray.xcframework.zip
#   LibAACS.xcframework.zip
#   LibBDPlus.xcframework.zip
#   checksums.txt
#
# Build-time requirements (macOS):
#   Xcode command line tools, meson >= 0.61, ninja, autoconf, automake,
#   libtool, pkg-config, flex, bison, curl, zip
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BLUEKIT_BUILD_DIR:-$REPO_ROOT/build}"
DL_DIR="$BUILD_DIR/downloads"
SRC_DIR="$BUILD_DIR/src"
WORK_DIR="$BUILD_DIR/work"
DIST_DIR="${BLUEKIT_DIST_DIR:-$REPO_ROOT/dist}"

ARCHS=("arm64" "x86_64")
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

# ---------------------------------------------------------------------------
# Pinned upstream sources: name|version|url|sha256
# ---------------------------------------------------------------------------
DEPS=(
  "libgpg-error|1.59|https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-1.59.tar.bz2|a19bc5087fd97026d93cb4b45d51638d1a25202a5e1fbc3905799f424cfa6134"
  "libgcrypt|1.12.4|https://gnupg.org/ftp/gcrypt/libgcrypt/libgcrypt-1.12.4.tar.bz2|d77f68f48879510e79a2f65977ccc68981781ea0923e5bdffac2a193ea3d660e"
  "libudfread|1.2.0|https://code.videolan.org/videolan/libudfread/-/archive/1.2.0/libudfread-1.2.0.tar.gz|adcce1190925f9d35a477757c5e3f0e221315d14d3d45b4ae62540ea0925f877"
  "libxml2|2.14.4|https://download.gnome.org/sources/libxml2/2.14/libxml2-2.14.4.tar.xz|24175ec30a97cfa86bdf9befb7ccf4613f8f4b2713c5103e0dd0bc9c711a2773"
  "freetype|2.13.3|https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz|0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289"
)

LIBS=(
  "libbluray|1.5.1|https://code.videolan.org/videolan/libbluray/-/archive/1.5.1/libbluray-1.5.1.tar.gz|ee46f99adc591d18a9485b404cb04be6ba6fcde5bd45590ea94d0c1432d448c9"
  "libaacs|0.12.0|https://code.videolan.org/videolan/libaacs/-/archive/0.12.0/libaacs-0.12.0.tar.gz|6ff08630aad2225b08df477f0ae2b8be0933ea5ebef8cfec809eb452a99dd8a2"
  "libbdplus|0.2.0|https://code.videolan.org/videolan/libbdplus/-/archive/0.2.0/libbdplus-0.2.0.tar.gz|936fa490d94334e667b2d2ec11e5e5d4e497f12bf55077630a97acf051583bea"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required build tool not found: $1"
}

nproc() { sysctl -n hw.ncpu 2>/dev/null || echo 4; }

# Prefer a Homebrew-provided tool over the (often outdated) one shipped with
# macOS. GitHub's macOS runners use /usr/local as the Homebrew prefix, but
# `brew --prefix` is asked directly so that this also works elsewhere.
prefer_brew_formula() {
  local formula="$1" prefix
  prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
  if [[ -n "$prefix" && -d "$prefix/bin" ]]; then
    PATH="$prefix/bin:$PATH"
  fi
}

# version_ge <have> <want> -> exit status 0 when have >= want
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]
}

# fetch <name> <version> <url> <sha256>
fetch() {
  local name="$1" version="$2" url="$3" sha="$4"
  local archive
  case "$url" in
    *.tar.gz)  archive="$DL_DIR/${name}-${version}.tar.gz" ;;
    *.tar.xz)  archive="$DL_DIR/${name}-${version}.tar.xz" ;;
    *.tar.bz2) archive="$DL_DIR/${name}-${version}.tar.bz2" ;;
    *)         archive="$DL_DIR/${name}-${version}.tar" ;;
  esac

  if [[ -f "$archive" ]]; then
    log "cached $(basename "$archive")"
  else
    log "downloading $name $version"
    mkdir -p "$DL_DIR"
    curl -fsSL --retry 3 --retry-delay 2 -o "$archive.part" "$url" \
      || die "download failed: $url"
    mv "$archive.part" "$archive"
  fi

  local actual
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [[ "$actual" == "$sha" ]] || die "checksum mismatch for $name-$version: expected $sha, got $actual"
}

# unpack <name> <version> -> echoes the pristine source directory
unpack() {
  local name="$1" version="$2"
  local dir="$SRC_DIR/${name}-${version}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$SRC_DIR"
    local archive
    archive="$(ls "$DL_DIR/${name}-${version}".tar.* 2>/dev/null | head -1)"
    [[ -n "$archive" ]] || die "no archive for $name-$version"
    log "unpacking $(basename "$archive")"
    tar -xf "$archive" -C "$SRC_DIR"
  fi
  echo "$dir"
}

# A private, per-architecture copy of a source tree. Autotools projects that
# generate sources (libaacs' KEYDB.cfg parser) do not build correctly out of
# tree, so they are configured in-tree inside this copy.
stage_source() {
  local name="$1" version="$2" arch="$3"
  local pristine
  pristine="$(unpack "$name" "$version")"
  local build="$WORK_DIR/${name}-${version}-${arch}"
  rm -rf "$build"
  mkdir -p "$WORK_DIR"
  cp -R "$pristine" "$build" || die "could not copy source tree for $name-$version"
  # Never carry key material into our tree.
  rm -f "$build/KEYDB.cfg"
  echo "$build"
}

# ---------------------------------------------------------------------------
# Per-architecture environment
# ---------------------------------------------------------------------------
setup_env_for_arch() {
  local arch="$1" stage="$2"

  export ARCH="$arch"
  export STAGE="$stage"

  # Always use Apple's own binutils. GNU binutils (Homebrew / MacPorts) create
  # archives Apple's linker rejects ("archive member ... is not 8-byte
  # aligned"), so put Xcode's tools first on PATH and point the build systems
  # at them explicitly.
  local tcbin="$WORK_DIR/toolchain-bin"
  mkdir -p "$tcbin"
  local t p
  for t in ar ranlib nm strip ld otool libtool install_name_tool dsymutil; do
    p="$(xcrun --find "$t" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$tcbin/$t"
  done
  export PATH="$tcbin:$PATH"

  export CC=clang
  export AR="$(xcrun --find ar)"
  export RANLIB="$(xcrun --find ranlib)"
  export NM="$(xcrun --find nm)"
  export STRIP="$(xcrun --find strip)"

  # Only ever look at our own staged prefix for pkg-config: Homebrew and
  # /usr/local libraries must never be linked in by accident. The sysroot
  # must stay empty, otherwise pkg-config would rewrite our absolute
  # include paths to live inside the SDK.
  export PKG_CONFIG_PATH="$stage/lib/pkgconfig"
  export PKG_CONFIG_LIBDIR="$stage/lib/pkgconfig"
  export PKG_CONFIG_SYSROOT_DIR=""

  export PATH="$stage/bin:$PATH"

  export CPPFLAGS="-I$stage/include"
  export CFLAGS="-O2 -fPIC -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -I$stage/include"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -L$stage/lib"

  # Autoconf needs to know that it is cross compiling, otherwise it tries to
  # *run* a binary built for the other architecture and gives up.
  local build_triplet host_triplet
  build_triplet="$(uname -m)-apple-darwin"
  host_triplet="$([ "$arch" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)"
  export BUILD_TRIPLET="$build_triplet"
  export HOST_TRIPLET="$host_triplet"

  # Meson cross file: meson must never try to *run* a binary built for the
  # other architecture while configuring.
  local cross_file="$WORK_DIR/cross-$arch.ini"
  cat > "$cross_file" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = ['$(xcrun --find ar)']
strip = ['$(xcrun --find strip)', '-arch', '$arch']
pkg-config = ['pkg-config']
exe_wrapper = ['/usr/bin/true']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = '$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)'
cpu = '$arch'
endian = 'little'

[built-in options]
c_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET']
c_link_args = ['-arch', '$arch', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET']
EOF
  export CROSS_FILE="$cross_file"
}

# ---------------------------------------------------------------------------
# Static dependency builds (installed into the per-arch stage prefix)
# ---------------------------------------------------------------------------

build_libgpg_error() {
  local src="$1" stage="$2"
  log "building libgpg-error (static) for $ARCH"
  local b="$WORK_DIR/libgpg-error-$ARCH"
  rm -rf "$b"; mkdir -p "$b"
  ( cd "$b" && "$src/configure" \
      --prefix="$stage" \
      --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
      --disable-shared --enable-static \
      --disable-nls --disable-doc --disable-tests \
      --disable-dependency-tracking \
      CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" ) > "$b/configure.log" 2>&1 \
    || { tail -40 "$b/configure.log"; die "libgpg-error configure failed"; }
  ( cd "$b" && make -j"$(nproc)" ) > "$b/build.log" 2>&1 \
    || { tail -40 "$b/build.log"; die "libgpg-error build failed"; }
  ( cd "$b" && make install ) > "$b/install.log" 2>&1 \
    || { tail -40 "$b/install.log"; die "libgpg-error install failed"; }
}

build_libgcrypt() {
  local src="$1" stage="$2"
  log "building libgcrypt (static) for $ARCH"
  local b="$WORK_DIR/libgcrypt-$ARCH"
  rm -rf "$b"; mkdir -p "$b"
  ( cd "$b" && "$src/configure" \
      --prefix="$stage" \
      --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
      --disable-shared --enable-static \
      --disable-nls --disable-doc --disable-tests \
      --disable-dependency-tracking \
      --disable-asm \
      --with-libgpg-error-prefix="$stage" \
      CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" ) > "$b/configure.log" 2>&1 \
    || { tail -40 "$b/configure.log"; die "libgcrypt configure failed"; }
  ( cd "$b" && make -j"$(nproc)" ) > "$b/build.log" 2>&1 \
    || { tail -40 "$b/build.log"; die "libgcrypt build failed"; }
  ( cd "$b" && make install ) > "$b/install.log" 2>&1 \
    || { tail -40 "$b/install.log"; die "libgcrypt install failed"; }
}

build_libudfread() {
  local src="$1" stage="$2"
  log "building libudfread (static) for $ARCH"
  local b="$WORK_DIR/libudfread-$ARCH"
  rm -rf "$b"
  meson setup "$b" "$src" \
      --cross-file "$CROSS_FILE" \
      --prefix="$stage" \
      --default-library=static \
      --libdir=lib \
      -Denable_examples=false \
      -Dembed_udfread=false > "$b.setup.log" 2>&1 \
    || { tail -40 "$b.setup.log"; die "libudfread meson setup failed"; }
  meson compile -C "$b" > "$b.build.log" 2>&1 \
    || { tail -40 "$b.build.log"; die "libudfread build failed"; }
  meson install -C "$b" --no-rebuild > "$b.install.log" 2>&1 \
    || { tail -40 "$b.install.log"; die "libudfread install failed"; }
}

build_libxml2() {
  local src="$1" stage="$2"
  log "building libxml2 (static) for $ARCH"
  local b="$WORK_DIR/libxml2-$ARCH"
  rm -rf "$b"
  meson setup "$b" "$src" \
      --cross-file "$CROSS_FILE" \
      --prefix="$stage" \
      --default-library=static \
      --libdir=lib \
      -Dhttp=disabled -Dpython=disabled -Dicu=disabled \
      -Dlzma=disabled -Dzlib=disabled -Diconv=disabled -Dcatalog=disabled \
      -Dhtml=disabled -Doutput=disabled -Dpattern=disabled -Dpush=disabled \
      -Dregexps=disabled -Dvalid=disabled -Dwriter=disabled \
      -Dxinclude=disabled -Dxpath=disabled -Dxptr=disabled -Dc14n=disabled \
      -Diso8859x=disabled -Dlegacy=disabled -Dtls=disabled -Dmodules=disabled \
      -Dhistory=disabled -Dreadline=disabled -Ddebugging=disabled \
      -Drelaxng=disabled -Dschematron=disabled -Dsax1=disabled \
      -Dschemas=disabled -Dthread-alloc=disabled -Dminimum=false \
      > "$b.setup.log" 2>&1 \
    || { tail -40 "$b.setup.log"; die "libxml2 meson setup failed"; }
  meson compile -C "$b" > "$b.build.log" 2>&1 \
    || { tail -40 "$b.build.log"; die "libxml2 build failed"; }
  meson install -C "$b" --no-rebuild > "$b.install.log" 2>&1 \
    || { tail -40 "$b.install.log"; die "libxml2 install failed"; }
}

build_freetype() {
  local src="$1" stage="$2"
  log "building freetype (static) for $ARCH"
  local b="$WORK_DIR/freetype-$ARCH"
  rm -rf "$b"
  meson setup "$b" "$src" \
      --cross-file "$CROSS_FILE" \
      --prefix="$stage" \
      --default-library=static \
      --libdir=lib \
      -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
      -Dpng=disabled -Dzlib=disabled -Dtests=disabled > "$b.setup.log" 2>&1 \
    || { tail -40 "$b.setup.log"; die "freetype meson setup failed"; }
  meson compile -C "$b" > "$b.build.log" 2>&1 \
    || { tail -40 "$b/build.log"; die "freetype build failed"; }
  meson install -C "$b" --no-rebuild > "$b.install.log" 2>&1 \
    || { tail -40 "$b/install.log"; die "freetype install failed"; }
}

# ---------------------------------------------------------------------------
# Dynamic library builds
# ---------------------------------------------------------------------------

build_libbluray() {
  local src="$1" stage="$2"
  log "building libbluray (shared) for $ARCH"
  local b="$WORK_DIR/libbluray-$ARCH"
  rm -rf "$b"

  # BD-J support needs both a JDK (javac) and Ant. It is enabled only when
  # both are available.
  local bdj="disabled"
  local want_bdj="${BLUEKIT_BUILD_BDJ:-auto}"
  if [[ "$want_bdj" == "always" ]]; then
    bdj="enabled"
  elif [[ "$want_bdj" == "auto" ]]; then
    if command -v javac >/dev/null 2>&1 && command -v ant >/dev/null 2>&1; then
      bdj="enabled"
    else
      warn "no JDK/Ant found - building libbluray without BD-J support"
    fi
  fi

  meson setup "$b" "$src" \
      --cross-file "$CROSS_FILE" \
      --prefix="$stage" \
      --libdir=lib \
      --buildtype=release \
      -Denable_tools=false \
      -Denable_devtools=false \
      -Denable_examples=false \
      -Denable_docs=false \
      -Dembed_udfread=false \
      -Dfreetype=enabled \
      -Dfontconfig=disabled \
      -Dlibxml2=enabled \
      -Dbdj_jar="$bdj" > "$b.setup.log" 2>&1 \
    || { tail -60 "$b.setup.log"; die "libbluray meson setup failed"; }
  meson compile -C "$b" > "$b.build.log" 2>&1 \
    || { tail -60 "$b.build.log"; die "libbluray build failed"; }
  meson install -C "$b" --no-rebuild > "$b.install.log" 2>&1 \
    || { tail -60 "$b/install.log"; die "libbluray install failed"; }

  # The public headers include "util/attributes.h", which upstream's meson
  # build does not install. Ship it so the headers are self-contained.
  mkdir -p "$stage/include/libbluray/util"
  cp "$src/src/util/attributes.h" "$stage/include/libbluray/util/attributes.h"
}

# libaacs / libbdplus only ship an autotools build system in their release
# archives, so `configure` is regenerated with autoreconf. They are then
# configured in-tree (see stage_source) because their generated sources do
# not build correctly from a separate build directory.
autoreconf_project() {
  local src="$1"
  log "running autoreconf in $(basename "$src")"

  # aclocal needs to find pkg.m4 (used by libaacs' configure.ac).
  local d
  for d in \
      "${BLUEKIT_TOOLS_PREFIX:-}/share/aclocal" \
      /usr/local/share/aclocal \
      /opt/local/share/aclocal \
      /usr/share/aclocal \
      "$(brew --prefix pkgconf 2>/dev/null || true)/share/aclocal"; do
    if [[ -n "$d" && -f "$d/pkg.m4" ]]; then
      export ACLOCAL_PATH="${ACLOCAL_PATH:+$ACLOCAL_PATH:}$d"
    fi
  done

  ( cd "$src" && autoreconf -vif ) > "$src/autoreconf.log" 2>&1 \
    || { tail -40 "$src/autoreconf.log"; die "autoreconf failed for $src"; }
}

build_libaacs() {
  local src="$1" stage="$2"
  log "building libaacs (shared) for $ARCH"
  autoreconf_project "$src"
  ( cd "$src" && ./configure \
      --prefix="$stage" \
      --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
      --enable-shared --disable-static \
      --disable-dependency-tracking \
      LIBGCRYPT_CFLAGS="-I$stage/include" \
      LIBGCRYPT_LIBS="-L$stage/lib -lgcrypt -lgpg-error" \
      GPG_ERROR_CFLAGS="-I$stage/include" \
      GPG_ERROR_LIBS="-L$stage/lib -lgpg-error" \
      LIBUDFREAD_CFLAGS="-I$stage/include" \
      LIBUDFREAD_LIBS="-L$stage/lib -ludfread" \
      CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" ) > "$src/configure.log" 2>&1 \
    || { tail -60 "$src/configure.log"; die "libaacs configure failed"; }
  ( cd "$src" && make -j"$(nproc)" ) > "$src/build.log" 2>&1 \
    || { tail -60 "$src/build.log"; die "libaacs build failed"; }
  ( cd "$src" && make install ) > "$src/install.log" 2>&1 \
    || { tail -60 "$src/install.log"; die "libaacs install failed"; }
}

build_libbdplus() {
  local src="$1" stage="$2"
  log "building libbdplus (shared) for $ARCH"
  autoreconf_project "$src"
  ( cd "$src" && ./configure \
      --prefix="$stage" \
      --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" \
      --enable-shared --disable-static \
      --disable-dependency-tracking \
      --without-libaacs \
      CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" ) > "$src/configure.log" 2>&1 \
    || { tail -60 "$src/configure.log"; die "libbdplus configure failed"; }
  ( cd "$src" && make -j"$(nproc)" ) > "$src/build.log" 2>&1 \
    || { tail -60 "$src/build.log"; die "libbdplus build failed"; }
  ( cd "$src" && make install ) > "$src/install.log" 2>&1 \
    || { tail -60 "$src/install.log"; die "libbdplus install failed"; }
}

# ---------------------------------------------------------------------------
# Packaging
# ---------------------------------------------------------------------------

# write_modulemap <output> <module> <header>...
write_modulemap() {
  local out="$1" module="$2"; shift 2
  {
    echo "module $module {"
    for h in "$@"; do
      echo "    header \"$h\""
    done
    echo "    export *"
    echo "}"
  } > "$out"
}

# package_xcframework <libfile> <module> <dylib> <stage> <outdir> <ship_jars> <header>...
package_xcframework() {
  local libfile="$1" module="$2" dylib="$3" stage="$4" outdir="$5" ship_jars="$6"
  shift 6
  local headers_rel=("$@")

  local bundle="$outdir/$module.xcframework"
  local contents="$bundle/macos-arm64_x86_64"
  rm -rf "$bundle"

  mkdir -p "$contents/Headers"
  local h src
  for h in "${headers_rel[@]}"; do
    src="$stage/include/$h"
    [[ -f "$src" ]] || die "header not found: $src"
    mkdir -p "$contents/Headers/$(dirname "$h")"
    cp "$src" "$contents/Headers/$h"
  done

  write_modulemap "$contents/Headers/module.modulemap" "$module" "${headers_rel[@]}"
  cp "$dylib" "$contents/$libfile"

  # libbluray's BD-J support loads its jars from the directory the library
  # was loaded from, so ship them next to the dylib.
  if [[ "$ship_jars" == "yes" && -d "$stage/share/java" ]]; then
    local jar
    for jar in "$stage/share/java"/*.jar; do
      [[ -e "$jar" ]] || continue
      cp "$jar" "$contents/"
      log "shipping $(basename "$jar") next to $libfile"
    done
  fi

  cat > "$bundle/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>macos-arm64_x86_64/$libfile</string>
			<key>HeadersPath</key>
			<string>macos-arm64_x86_64/Headers</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>$libfile</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

  # When Xcode is available, regenerate the bundle with xcodebuild so the
  # metadata is exactly what Apple's tooling produces.
  if xcodebuild -version >/dev/null 2>&1; then
    local tmp="$outdir/.tmp-$module.xcframework"
    rm -rf "$tmp"
    if xcodebuild -create-xcframework \
        -library "$contents/$libfile" \
        -headers "$contents/Headers" \
        -output "$tmp" > "$outdir/.xcodebuild-$module.log" 2>&1; then
      # xcodebuild does not carry a module map over - put ours back.
      local newcontents
      newcontents="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d | head -1)"
      if [[ -n "$newcontents" ]]; then
        mkdir -p "$newcontents/Headers"
        cp "$contents/Headers/module.modulemap" "$newcontents/Headers/module.modulemap"
        # Keep the BD-J jars next to the library.
        local jar
        for jar in "$contents"/*.jar; do
          [[ -e "$jar" ]] || continue
          cp "$jar" "$newcontents/"
        done
        rm -rf "$bundle"
        mv "$tmp" "$bundle"
      else
        warn "xcodebuild produced an empty xcframework for $module"
      fi
    else
      warn "xcodebuild -create-xcframework failed for $module - using the hand-written Info.plist"
      tail -20 "$outdir/.xcodebuild-$module.log" >&2 || true
    fi
    rm -rf "$tmp"
  fi

  ( cd "$outdir" && zip -qry "$(basename "$bundle").zip" "$(basename "$bundle")" )
  rm -rf "$bundle"
  log "packaged $(basename "$bundle").zip"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # Prefer the tools installed by scripts/install-build-tools.sh, otherwise
  # fall back to modern Homebrew tools (macOS ships an outdated meson 0.59 and
  # bison 2.3, both too old for these projects).
  if [[ -n "${BLUEKIT_TOOLS_PREFIX:-}" && -d "${BLUEKIT_TOOLS_PREFIX}/bin" ]]; then
    PATH="${BLUEKIT_TOOLS_PREFIX}/bin:$PATH"
  else
    local formula
    for formula in meson ninja pkg-config bison flex ant autoconf automake libtool; do
      prefer_brew_formula "$formula"
    done
  fi

  for t in curl tar unzip zip shasum lipo install_name_tool meson ninja \
           pkg-config autoreconf automake libtool make flex bison clang; do
    need_tool "$t"
  done

  # meson >= 0.61 is required by libudfread / libxml2.
  local mv bv
  mv="$(meson --version)"
  version_ge "$mv" "0.61.0" || die "meson >= 0.61 required, found $mv (macOS ships an old meson; install a newer one, e.g. 'brew install meson')"

  # bison >= 3.0 is required by libaacs' KEYDB.cfg grammar (%define api.pure).
  bv="$(bison --version | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  version_ge "${bv:-0}" "3.0" || die "bison >= 3.0 required, found ${bv:-unknown} (macOS ships bison 2.3; install a newer one, e.g. 'brew install bison')"

  export SDKROOT="$(xcrun --show-sdk-path)"
  [[ -d "$SDKROOT" ]] || die "no macOS SDK found (xcrun --show-sdk-path failed)"

  log "meson $mv, bison $bv, SDK $SDKROOT, deployment target $MACOSX_DEPLOYMENT_TARGET"

  mkdir -p "$BUILD_DIR" "$DL_DIR" "$SRC_DIR" "$WORK_DIR" "$DIST_DIR"

  # Fetch + verify all pinned tarballs up-front.
  local entry name version url sha
  for entry in "${DEPS[@]}" "${LIBS[@]}"; do
    IFS='|' read -r name version url sha <<< "$entry"
    fetch "$name" "$version" "$url" "$sha"
  done

  local arch stage src
  for arch in "${ARCHS[@]}"; do
    stage="$BUILD_DIR/stage-$arch"
    rm -rf "$stage"
    mkdir -p "$stage/lib" "$stage/include"
    setup_env_for_arch "$arch" "$stage"

    for entry in "${DEPS[@]}"; do
      IFS='|' read -r name version url sha <<< "$entry"
      src="$(unpack "$name" "$version")"
      case "$name" in
        libgpg-error) build_libgpg_error "$src" "$stage" ;;
        libgcrypt)    build_libgcrypt    "$src" "$stage" ;;
        libudfread)   build_libudfread   "$src" "$stage" ;;
        libxml2)      build_libxml2      "$src" "$stage" ;;
        freetype)     build_freetype     "$src" "$stage" ;;
      esac
    done

    for entry in "${LIBS[@]}"; do
      IFS='|' read -r name version url sha <<< "$entry"
      case "$name" in
        libbluray)
          src="$(unpack "$name" "$version")"
          build_libbluray "$src" "$stage"
          ;;
        libaacs|libbdplus)
          src="$(stage_source "$name" "$version" "$arch")"
          if [[ "$name" == "libaacs" ]]; then
            build_libaacs "$src" "$stage"
          else
            build_libbdplus "$src" "$stage"
          fi
          ;;
      esac
    done
  done

  # ---------------------------------------------------------------------
  # Combine the two architectures and fix up install names.
  # ---------------------------------------------------------------------
  local combined="$WORK_DIR/combined"
  rm -rf "$combined"; mkdir -p "$combined"

  combine_dylib() {
    local name="$1" a="$2" b="$3" out="$4"
    local pa="$a/lib/$name" pb="$b/lib/$name"
    [[ -f "$pa" ]] || die "missing $pa"
    [[ -f "$pb" ]] || die "missing $pb"
    lipo -create "$pa" "$pb" -output "$out"
    install_name_tool -id "@rpath/$name" "$out"
    log "$(basename "$out"): $(lipo -archs "$out")"
  }

  combine_dylib "libbluray.dylib"  "$BUILD_DIR/stage-arm64" "$BUILD_DIR/stage-x86_64" "$combined/libbluray.dylib"
  combine_dylib "libaacs.dylib"    "$BUILD_DIR/stage-arm64" "$BUILD_DIR/stage-x86_64" "$combined/libaacs.dylib"
  combine_dylib "libbdplus.dylib"  "$BUILD_DIR/stage-arm64" "$BUILD_DIR/stage-x86_64" "$combined/libbdplus.dylib"

  # ---------------------------------------------------------------------
  # Package.
  # ---------------------------------------------------------------------
  rm -f "$DIST_DIR"/*.xcframework.zip "$DIST_DIR/checksums.txt"

  package_xcframework "libbluray.dylib" "LibBluray" "$combined/libbluray.dylib" \
      "$BUILD_DIR/stage-arm64" "$DIST_DIR" yes \
      libbluray/bluray.h libbluray/overlay.h libbluray/keys.h libbluray/meta_data.h \
      libbluray/filesystem.h libbluray/log_control.h libbluray/player_settings.h \
      libbluray/clpi_data.h libbluray/bluray-version.h libbluray/util/attributes.h

  package_xcframework "libaacs.dylib" "LibAACS" "$combined/libaacs.dylib" \
      "$BUILD_DIR/stage-arm64" "$DIST_DIR" no \
      libaacs/aacs.h libaacs/aacs-version.h libaacs/filesystem.h

  package_xcframework "libbdplus.dylib" "LibBDPlus" "$combined/libbdplus.dylib" \
      "$BUILD_DIR/stage-arm64" "$DIST_DIR" no \
      libbdplus/bdplus.h libbdplus/bdplus-version.h

  # ---------------------------------------------------------------------
  # Checksums
  # ---------------------------------------------------------------------
  : > "$DIST_DIR/checksums.txt"
  local z base
  for z in "$DIST_DIR"/*.xcframework.zip; do
    base="$(basename "$z")"
    # "<sha256>  <filename>" - the same format `shasum -a 256 -c` expects.
    printf '%s  %s\n' \
      "$( cd "$DIST_DIR" && swift package compute-checksum "$base" )" \
      "$base" >> "$DIST_DIR/checksums.txt"
  done
  cat "$DIST_DIR/checksums.txt"

  rm -f "$DIST_DIR"/.xcodebuild-*.log

  log "done - artifacts in $DIST_DIR"
}

main "$@"
