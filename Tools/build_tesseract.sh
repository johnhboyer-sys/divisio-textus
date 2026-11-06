#!/bin/bash
# Builds a self-contained, universal (arm64 + x86_64) tesseract command-line
# tool with its language data, for bundling inside the app. Re-runnable.
# Output goes to .build-tesseract/out/. If that holds a finished build, the
# script does nothing; pass --clean to rebuild from scratch.
set -euo pipefail

LEPT_VER="1.87.0"
LEPT_SHA="c73363397f96eb1295602bf44d708a994ad42046c791bf03ea0505d829bdb6a7"
TESS_VER="5.5.2"
TESS_SHA="6235ea0dae45ea137f59c09320406f5888383741924d98855bd2ce0d16b54f21"
# tessdata commits (not branches), so the files cannot change under us.
BEST_COMMIT="e12c65a915945e4c28e237a9b52bc4a8f39a0cec"
FAST_COMMIT="87416418657359cb625c412a48b6e1d6d41c29bd"
GRC_SHA="dfc9bda286cd9d8755b1832e5731a5425d1cf0803393a5fa6dee078466178cf1"
GRC_SIZE=5168122
ENG_SHA="7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2"
ENG_SIZE=4113088

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$PROJ_DIR/.build-tesseract"
OUT="$WORK/out"
DL="$WORK/downloads"
CMAKE="$(command -v cmake || echo /opt/homebrew/bin/cmake)"
# pkg-config would find Homebrew libraries that cmake's ignore list misses.
export PKG_CONFIG_LIBDIR=/nonexistent PKG_CONFIG_PATH=

if [ "${1:-}" = "--clean" ]; then
    rm -rf "$WORK/out" "$WORK/src" "$WORK/build" "$WORK/prefix"
fi

if [ -x "$OUT/tesseract" ] && [ -f "$OUT/tessdata/grc.traineddata" ] \
   && [ -f "$OUT/tessdata/eng.traineddata" ] && [ -f "$OUT/licenses/Tesseract-LICENSE.txt" ] \
   && [ -f "$OUT/licenses/Leptonica-LICENSE.txt" ]; then
    echo "==> tesseract already built: $OUT/tesseract (use --clean to rebuild)"
    exit 0
fi

mkdir -p "$DL"
rm -rf "$OUT" "$WORK/src" "$WORK/build" "$WORK/prefix"
mkdir -p "$WORK/src" "$WORK/build" "$WORK/prefix"

# Fetch a file once, then check its size-independent sha256 every run.
fetch() {   # url file sha256
    [ -f "$DL/$2" ] || curl -fsSL -o "$DL/$2" "$1"
    local got; got="$(shasum -a 256 "$DL/$2" | cut -d' ' -f1)"
    [ "$got" = "$3" ] || { echo "sha256 mismatch for $2: $got"; rm -f "$DL/$2"; exit 1; }
}

echo "==> Downloading sources and language data"
fetch "https://github.com/DanBloomberg/leptonica/releases/download/$LEPT_VER/leptonica-$LEPT_VER.tar.gz" "leptonica-$LEPT_VER.tar.gz" "$LEPT_SHA"
fetch "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/$TESS_VER.tar.gz" "tesseract-$TESS_VER.tar.gz" "$TESS_SHA"
fetch "https://github.com/tesseract-ocr/tessdata_best/raw/$BEST_COMMIT/grc.traineddata" "grc.traineddata" "$GRC_SHA"
fetch "https://github.com/tesseract-ocr/tessdata_fast/raw/$FAST_COMMIT/eng.traineddata" "eng.traineddata" "$ENG_SHA"
[ "$(stat -f%z "$DL/grc.traineddata")" = "$GRC_SIZE" ] || { echo "grc.traineddata has the wrong size"; exit 1; }
[ "$(stat -f%z "$DL/eng.traineddata")" = "$ENG_SIZE" ] || { echo "eng.traineddata has the wrong size"; exit 1; }

tar -xzf "$DL/leptonica-$LEPT_VER.tar.gz" -C "$WORK/src"
tar -xzf "$DL/tesseract-$TESS_VER.tar.gz" -C "$WORK/src"

# Flags both builds share. CMAKE_IGNORE_PREFIX_PATH keeps cmake away from
# Homebrew's libraries, so nothing outside the macOS system gets linked.
COMMON=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
    -DBUILD_SHARED_LIBS=OFF
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
    -DCMAKE_FIND_FRAMEWORK=NEVER
    -DCMAKE_PREFIX_PATH="$WORK/prefix"
    -DCMAKE_INSTALL_PREFIX="$WORK/prefix"
)
JOBS="$(sysctl -n hw.ncpu)"

echo "==> Building Leptonica $LEPT_VER"
"$CMAKE" -S "$WORK/src/leptonica-$LEPT_VER" -B "$WORK/build/lept" "${COMMON[@]}" \
    -DBUILD_PROG=OFF -DSW_BUILD=OFF \
    -DENABLE_ZLIB=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF -DENABLE_JPEG=OFF \
    -DENABLE_TIFF=OFF -DENABLE_WEBP=OFF -DENABLE_OPENJPEG=OFF
"$CMAKE" --build "$WORK/build/lept" -j "$JOBS"
"$CMAKE" --install "$WORK/build/lept"

# Tesseract's cmake picks its SIMD code (NEON or SSE/AVX) from the build host,
# so a one-pass universal build fails to link. Build each arch alone, then lipo.
# Naming the system makes cmake trust the arch we give it, which also means it
# cannot run test programs, so we answer the one it asks (no TIFF in Leptonica).
SLICES=()
for ARCH in arm64 x86_64; do
    echo "==> Building Tesseract $TESS_VER ($ARCH)"
    COMMON_ARCH=("${COMMON[@]/CMAKE_OSX_ARCHITECTURES=*/CMAKE_OSX_ARCHITECTURES=$ARCH}")
    "$CMAKE" -S "$WORK/src/tesseract-$TESS_VER" -B "$WORK/build/tess-$ARCH" "${COMMON_ARCH[@]}" \
        -DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
        -DLEPT_TIFF_RESULT=1 \
        -DSW_BUILD=OFF -DOPENMP_BUILD=OFF -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF \
        -DDISABLE_CURL=ON -DDISABLE_ARCHIVE=ON -DGRAPHICS_DISABLED=ON
    "$CMAKE" --build "$WORK/build/tess-$ARCH" -j "$JOBS" --target tesseract
    BIN="$(find "$WORK/build/tess-$ARCH" -type f -name tesseract -perm -u+x | head -1)"
    [ -n "$BIN" ] || { echo "tesseract binary not produced ($ARCH)"; exit 1; }
    SLICES+=("$BIN")
done

echo "==> Collecting output"
mkdir -p "$OUT/tessdata" "$OUT/licenses"
lipo -create "${SLICES[@]}" -output "$OUT/tesseract"
strip -x "$OUT/tesseract"
cp "$DL/grc.traineddata" "$DL/eng.traineddata" "$OUT/tessdata/"
cp "$WORK/src/tesseract-$TESS_VER/LICENSE" "$OUT/licenses/Tesseract-LICENSE.txt"
cp "$WORK/src/leptonica-$LEPT_VER/leptonica-license.txt" "$OUT/licenses/Leptonica-LICENSE.txt"

# Refuse a binary that links anything beyond the macOS system.
if otool -L "$OUT/tesseract" | grep $'^\t' | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)'; then
    echo "tesseract links a library outside the system"; exit 1
fi
echo "==> Done: $OUT/tesseract ($(lipo -archs "$OUT/tesseract"))"
