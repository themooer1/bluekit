# BlueKit

BlueKit is a prebuilt macOS `XCFramework` distribution of the native C libraries used to read, navigate and interact with Blu-ray discs. It packages `libbluray`, `libaacs` and `libbdplus` as universal (`arm64` + `x86_64`) dynamic libraries for macOS 13 and later, so Swift and Xcode projects can use them without installing Homebrew.

## Latest Release

<https://github.com/themooer1/bluekit/releases/latest>

## How to Use

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/themooer1/bluekit.git", from: "0.1.0")
],
targets: [
    .executableTarget(name: "MyApp", dependencies: [.product(name: "BlueKit", package: "bluekit")])
]
```

Then import it and call the upstream C API:

```swift
import BlueKit

var major: Int32 = 0, minor: Int32 = 0, micro: Int32 = 0
bd_get_version(&major, &minor, &micro)
print("libbluray \(major).\(minor).\(micro)")
```

`BlueKit` re-exports the `LibBluray`, `LibAACS` and `LibBDPlus` C modules, so `bd_open`, `bd_get_title`, `bd_get_event`, `bd_user_input` and the rest of the upstream API are available directly.

> **Note:** BlueKit contains no AACS keys and no proprietary decryption material. The AACS and BD+ libraries are shipped in their unmodified upstream state.

## How to Build

Build the XCFrameworks locally (requires macOS with Xcode, `meson` >= 0.61, `ninja`, `autoconf`, `automake`, `libtool`, `pkg-config`, `flex` and `bison`):

```sh
./scripts/build-xcframeworks.sh
```

The script downloads pinned upstream source tarballs, verifies their SHA-256 checksums, compiles every library from source for `arm64` and `x86_64`, and writes `LibBluray.xcframework.zip`, `LibAACS.xcframework.zip`, `LibBDPlus.xcframework.zip` and `checksums.txt` into `dist/`.

Releases are produced by GitHub Actions: push a tag matching `v*` (for example `v0.1.0`) and the [release workflow](.github/workflows/release.yml) builds the XCFrameworks on a macOS runner and publishes them as release assets.

## Licensing

The build scripts and packaging in this repository are released under the [MIT license](LICENSE).

The bundled libraries keep their own licenses. `libbluray`, `libaacs` and `libbdplus` are licensed under the **LGPL-2.1+** and are distributed here as **dynamic libraries** so that downstream applications remain dynamically linked.

| Library | Version | License |
| --- | --- | --- |
| [libbluray](https://code.videolan.org/videolan/libbluray) | 1.5.1 | LGPL-2.1+ |
| [libaacs](https://code.videolan.org/videolan/libaacs) | 0.12.0 | LGPL-2.1+ |
| [libbdplus](https://code.videolan.org/videolan/libbdplus) | 0.2.0 | LGPL-2.1+ |
| [libudfread](https://code.videolan.org/videolan/libudfread) | 1.2.0 | LGPL-2.1+ |
| [freetype](https://freetype.org) | 2.13.3 | FTL or GPL-2.0-or-later |
| [libxml2](https://gitlab.gnome.org/GNOME/libxml2) | 2.14.4 | MIT |
| [libgcrypt](https://gnupg.org/ftp/gcrypt/libgcrypt/) | 1.12.4 | LGPL-2.1+ |
| [libgpg-error](https://gnupg.org/ftp/gcrypt/libgpg-error/) | 1.59 | LGPL-2.1+ |

The permissive transitive dependencies (`libudfread`, `freetype`, `libxml2`, `libgcrypt`, `libgpg-error`) are linked **statically** into the shipped dynamic libraries, so the XCFrameworks have no external Homebrew or `/usr/local` runtime dependencies. Full license texts are in [LICENSES/](LICENSES/).
