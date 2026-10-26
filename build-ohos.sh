#!/usr/bin/env bash
#
# Build DuckDB for HarmonyOS (OHOS, aarch64, musl).
#
# Examples:
#   ./build-ohos.sh --clean                 # fresh Release build in build/ohos-release
#   ./build-ohos.sh --package               # incremental build + tar.gz dev package
#   ./build-ohos.sh --build-type Debug --build-dir build/ohos-debug --package --strip
#
# Environment:
#   OHOS_SDK   path to the OHOS SDK "native" directory (auto-detected by default)
#
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BUILD_TYPE="Release"
BUILD_DIR=""
SDK_DIR="${OHOS_SDK:-}"
JOBS=""
DO_CLEAN=0
DO_PACKAGE=0
DO_STRIP=0
EXPLICIT_VERSION=""

usage() {
	cat <<'EOF'
Usage: build-ohos.sh [options]

Options:
  --build-dir DIR      Build directory (default: build/ohos-<lowercase-build-type>)
  --build-type TYPE    Release (default), RelWithDebInfo or Debug
  --sdk DIR            OHOS SDK native directory (default: newest installed SDK)
  --jobs N             Parallel compile jobs (default: all CPUs)
  --version VERSION    Version to report, e.g. v2.0.0 (default: git-derived dev version)
  --clean              Remove the build directory before configuring
  --package            Create build/dist/duckdb-<version>-ohos-arm64.tar.gz
  --strip              Strip libduckdb.so (the shell keeps its OHOS code signature)
  -h, --help           Show this help

The build always targets aarch64 HarmonyOS using the musl platform
(DUCKDB_PLATFORM=linux_arm64_musl), with jemalloc and the json extension,
matching the verified OHOS configuration.
EOF
}

die() {
	echo "error: $*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--build-dir)
		[ $# -ge 2 ] || die "--build-dir requires a value"
		BUILD_DIR="$2"
		shift 2
		;;
	--build-type)
		[ $# -ge 2 ] || die "--build-type requires a value"
		BUILD_TYPE="$2"
		shift 2
		;;
	--sdk)
		[ $# -ge 2 ] || die "--sdk requires a value"
		SDK_DIR="$2"
		shift 2
		;;
	--jobs)
		[ $# -ge 2 ] || die "--jobs requires a value"
		JOBS="$2"
		shift 2
		;;
	--version)
		[ $# -ge 2 ] || die "--version requires a value"
		EXPLICIT_VERSION="$2"
		shift 2
		;;
	--clean)
		DO_CLEAN=1
		shift
		;;
	--package)
		DO_PACKAGE=1
		shift
		;;
	--strip)
		DO_STRIP=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown option: $1 (use --help)"
		;;
	esac
done

case "$BUILD_TYPE" in
Release | RelWithDebInfo | Debug) ;;
*) die "unsupported build type: $BUILD_TYPE" ;;
esac

BUILD_TYPE_LOWER=$(printf '%s' "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')
[ -n "$BUILD_DIR" ] || BUILD_DIR="$ROOT_DIR/build/ohos-$BUILD_TYPE_LOWER"
case "$BUILD_DIR" in
/*) ;;
*) BUILD_DIR="$ROOT_DIR/$BUILD_DIR" ;;
esac

if [ -z "$JOBS" ]; then
	JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)
fi

# --- locate the OHOS SDK -----------------------------------------------------

normalize_sdk() {
	local dir="$1"
	if [ -x "$dir/llvm/bin/aarch64-unknown-linux-ohos-clang++" ] && [ -d "$dir/sysroot" ]; then
		printf '%s\n' "$dir"
	elif [ -x "$dir/native/llvm/bin/aarch64-unknown-linux-ohos-clang++" ] && [ -d "$dir/native/sysroot" ]; then
		printf '%s\n' "$dir/native"
	else
		return 1
	fi
}

if [ -n "$SDK_DIR" ]; then
	SDK_DIR=$(normalize_sdk "$SDK_DIR") || die "no usable OHOS SDK at $SDK_DIR (need native/llvm/bin + native/sysroot)"
else
	CANDIDATES=""
	for dir in "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/native; do
		[ -d "$dir" ] || continue
		[ -x "$dir/llvm/bin/aarch64-unknown-linux-ohos-clang++" ] || continue
		[ -d "$dir/sysroot" ] || continue
		CANDIDATES="$CANDIDATES$dir"$'\n'
	done
	[ -n "$CANDIDATES" ] || die "no OHOS SDK found under $HOME/.harmonybrew/Cellar/ohos-sdk (set OHOS_SDK or --sdk)"
	# Directory names sort by SDK version, so the last line is the newest SDK.
	SDK_DIR=$(printf '%s' "$CANDIDATES" | sort | tail -n 1)
fi

CC="$SDK_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang"
CXX="$SDK_DIR/llvm/bin/aarch64-unknown-linux-ohos-clang++"
LLD="$SDK_DIR/llvm/bin/ld.lld"
[ -x "$LLD" ] || LLD="$SDK_DIR/llvm/bin/lld"
[ -x "$CC" ] && [ -x "$CXX" ] || die "OHOS clang not found under $SDK_DIR/llvm/bin"

# The SDK's lld links against libxml2.so.16, which is not always resolvable
# from the default search path. Pick a directory where lld actually runs.
find_lld_lib_dir() {
	local dir
	for dir in "$SDK_DIR/llvm/lib" "$HOME"/.harmonybrew/Cellar/ohos-sdk/*/native/llvm/lib "$HOME"/.harmonybrew/lib; do
		[ -e "$dir/libxml2.so.16" ] || continue
		if LD_LIBRARY_PATH="$dir" "$LLD" --version >/dev/null 2>&1; then
			printf '%s\n' "$dir"
			return 0
		fi
	done
	return 1
}

LLD_LIB_DIR=$(find_lld_lib_dir) || die "could not find a libxml2.so.16 that lets $LLD run"

echo "==> DuckDB OHOS build"
echo "    SDK:        $SDK_DIR"
echo "    build dir:  $BUILD_DIR"
echo "    build type: $BUILD_TYPE"
echo "    jobs:       $JOBS"
echo "    lld libs:   $LLD_LIB_DIR"
if [ -n "$EXPLICIT_VERSION" ]; then
	echo "    version:    $EXPLICIT_VERSION"
fi

# --- configure and build -----------------------------------------------------

if [ "$DO_CLEAN" = 1 ]; then
	echo "==> removing $BUILD_DIR"
	rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

VERSION_ARG=()
if [ -n "$EXPLICIT_VERSION" ]; then
	VERSION_ARG=(-DDUCKDB_EXPLICIT_VERSION="$EXPLICIT_VERSION")
fi

LD_LIBRARY_PATH="$LLD_LIB_DIR" DUCKDB_PLATFORM=linux_arm64_musl cmake -G Ninja \
	-B "$BUILD_DIR" \
	-DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
	-DCMAKE_C_COMPILER="$CC" \
	-DCMAKE_CXX_COMPILER="$CXX" \
	-DCMAKE_C_FLAGS="-fPIC -O2" \
	-DCMAKE_CXX_FLAGS="-fPIC -O2" \
	-DBUILD_EXTENSIONS=json \
	-DENABLE_JEMALLOC=ON \
	-DDUCKDB_EXPLICIT_PLATFORM=linux_arm64_musl \
	${VERSION_ARG[@]+"${VERSION_ARG[@]}"}

echo "==> building"
LD_LIBRARY_PATH="$LLD_LIB_DIR" cmake --build "$BUILD_DIR" --parallel "$JOBS"

[ -x "$BUILD_DIR/duckdb" ] || die "build finished but $BUILD_DIR/duckdb is missing"

# --- package ----------------------------------------------------------------

package() {
	local cli="$BUILD_DIR/duckdb"
	local version name dist stage
	local strip_tool="$SDK_DIR/llvm/bin/llvm-strip"

	version=$("$cli" -noheader -list -c "select version()" 2>/dev/null | head -n 1)
	[ -n "$version" ] || version=$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || git -C "$ROOT_DIR" rev-parse --short HEAD)
	name="duckdb-${version}-ohos-arm64"
	dist="$BUILD_DIR/dist"
	mkdir -p "$dist"
	stage=$(mktemp -d "$dist/.stage.XXXXXX")
	trap 'rm -rf "$stage"' EXIT

	echo "==> packaging $name"
	cmake --install "$BUILD_DIR" --prefix "$stage/$name" >/dev/null

	mkdir -p "$stage/$name/bin"
	cp "$cli" "$stage/$name/bin/duckdb"
	cp "$ROOT_DIR/LICENSE" "$stage/$name/"
	if [ -f "$ROOT_DIR/THIRD-PARTY-NOTICES.TXT" ]; then
		cp "$ROOT_DIR/THIRD-PARTY-NOTICES.TXT" "$stage/$name/"
	fi

	# The install rules omit the local extension repository archive and do not
	# ship a loader for the statically linked extensions. Add both so that
	# static consumers get the same extensions as the shell.
	local loader_c="$BUILD_DIR/src/duckdb_static_extension_loader.c"
	local repo_lib="$BUILD_DIR/src/main/extension/local_extension_repository/libduckdb_local_extension_repository.a"
	local ar="$SDK_DIR/llvm/bin/llvm-ar"
	if [ -f "$loader_c" ] && [ -f "$repo_lib" ] && [ -x "$ar" ]; then
		cp "$repo_lib" "$stage/$name/lib/"
		"$CC" -O2 -fPIC -I"$stage/$name/include" -c "$loader_c" -o "$stage/loader.o"
		"$ar" rcs "$stage/$name/lib/libduckdb_static_extensions.a" "$stage/loader.o"
		rm -f "$stage/loader.o"
		cat >"$stage/$name/lib/cmake/DuckDB/DuckDBStaticExtensions.cmake" <<'EOF'
# Extra imported targets for static DuckDB consumers.
# Include this file after find_package(DuckDB).

if(NOT TARGET duckdb_local_extension_repository)
  add_library(duckdb_local_extension_repository STATIC IMPORTED)
  set_target_properties(
    duckdb_local_extension_repository
    PROPERTIES IMPORTED_LOCATION
               "${CMAKE_CURRENT_LIST_DIR}/../../libduckdb_local_extension_repository.a")
endif()

if(NOT TARGET duckdb_static_extensions)
  add_library(duckdb_static_extensions STATIC IMPORTED)
  set_target_properties(
    duckdb_static_extensions
    PROPERTIES IMPORTED_LOCATION
               "${CMAKE_CURRENT_LIST_DIR}/../../libduckdb_static_extensions.a")
endif()
EOF
	else
		echo "warning: static extension loader inputs not found, packaging without static extension support" >&2
	fi

	cat >"$stage/$name/README.md" <<EOF
# DuckDB $version for HarmonyOS (arm64)

Built with the OHOS SDK (aarch64-unknown-linux-ohos, musl).

## Layout

- \`bin/duckdb\` - command line shell
- \`include/\` - C and C++ headers
- \`lib/libduckdb.so\` - shared library
- \`lib/libduckdb_static.a\` - static library (with bundled extension archives)
- \`lib/cmake/DuckDB\` - CMake package config

The shell is shipped unstripped: OHOS verifies its \`.codesign\` section on exec.

## CMake (shared, recommended)

\`\`\`cmake
find_package(DuckDB REQUIRED)
target_include_directories(app PRIVATE \${DuckDB_INCLUDE_DIRS})
target_link_libraries(app PRIVATE duckdb)
\`\`\`

Point \`CMAKE_PREFIX_PATH\` at this directory when configuring.

## CMake (static)

Static consumers have to register the bundled extensions before opening a
database. Import the extra targets and link the loader archive:

\`\`\`cmake
find_package(DuckDB REQUIRED)
include(\${DuckDB_DIR}/DuckDBStaticExtensions.cmake)
target_include_directories(app PRIVATE \${DuckDB_INCLUDE_DIRS})
target_link_libraries(app PRIVATE
  duckdb_static_extensions
  core_functions_extension parquet_extension json_extension icu_extension
  duckdb_loadable_extensions duckdb_httplib
  duckdb_local_extension_repository
  duckdb_static)
\`\`\`

Then call \`duckdb_register_static_extensions()\` once before \`duckdb_open()\`:

\`\`\`c
#include <duckdb_static_extension.h>

duckdb_register_static_extensions();
\`\`\`

## Shell

\`\`\`sh
./bin/duckdb -c "select version(), platform"
\`\`\`
EOF

	if [ "$DO_STRIP" = 1 ]; then
		[ -x "$strip_tool" ] || die "llvm-strip not found at $strip_tool"
		# The shell cannot be stripped: OHOS verifies its .codesign section on
		# exec, so removing or modifying sections makes the binary unusable.
		"$strip_tool" --strip-all "$stage/$name/lib/libduckdb.so"
	fi

	tar -czf "$dist/$name.tar.gz" -C "$stage" "$name"
	trap - EXIT
	rm -rf "$stage"

	echo "==> package: $dist/$name.tar.gz ($(du -h "$dist/$name.tar.gz" | cut -f 1))"
}

if [ "$DO_PACKAGE" = 1 ]; then
	package
fi

echo "==> done"
echo "    duckdb:      $BUILD_DIR/duckdb"
echo "    libduckdb:   $BUILD_DIR/src/libduckdb.so"
echo "    unittest:    $BUILD_DIR/test/unittest"
