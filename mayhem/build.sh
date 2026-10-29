#!/usr/bin/env bash
#
# mayhem/build.sh — build libass's fuzz harness (sanitized, DWARF-3) and the oracle (normal flags).
# Runs inside the commit image as `mayhem` in /mayhem. Re-runnable and offline: dependencies are apt
# -dev packages baked into the image; build dirs live under mayhem/build/ (gitignored) and are
# recreated on every run.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
BUILD="$SRC/mayhem/build"
rm -rf "$BUILD"
mkdir -p "$BUILD"

MESON_COMMON=(-Dasm=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled
              -Dcheckasm=disabled -Ddefault_library=static -Ddebug=false -Doptimization=2)

# 1) Sanitized libass. fuzzer-no-link adds SanCov to the library so Mayhem sees its edges.
# shellcheck disable=SC2086
meson setup "$BUILD/fuzz" "${MESON_COMMON[@]}" \
    -Dc_args="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
    -Dc_link_args="$SANITIZER_FLAGS" >/dev/null
ninja -C "$BUILD/fuzz" -j"$MAYHEM_JOBS" libass/libass.a

# Link flags for libass's own dependencies (freetype, fribidi, harfbuzz, fontconfig, unibreak).
LIBS="$(PKG_CONFIG_PATH="$BUILD/fuzz/meson-private" pkg-config --libs --static libass | sed 's/-lass\b//')"

# 2) LeakSanitizer off, at build time (leaks are not the bug class this fleet fuzzes for).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"

# 3) A one-font fontconfig sysroot. The harness rebuilds the library and renderer on every input, and
#    with the system's full font set each exec costs ~100 ms; with one font it is a few ms. Same trick
#    as OSS-Fuzz (fuzz.c honours ASSFUZZ_FONTCONFIG_SYSROOT). The fontconfig cache is pre-built here
#    because the image is read-only while Mayhem collects coverage.
FS="$BUILD/fontsysroot"
mkdir -p "$FS/etc/fonts" "$FS/usr/share/fonts" "$FS/var/cache/fontconfig"
cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf "$FS/usr/share/fonts/"
cat > "$FS/etc/fonts/fonts.conf" <<'FCEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>/usr/share/fonts</dir>
  <cachedir>/var/cache/fontconfig</cachedir>
</fontconfig>
FCEOF
FONTCONFIG_SYSROOT="$FS" fc-cache -f

# 4) The harness is upstream's own fuzz/fuzz.c in libFuzzer mode (ASS_FUZZMODE=2, the OSS-Fuzz
#    libass_fuzzer target), linked twice: with libFuzzer, and with the run-once standalone driver.
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DASS_FUZZMODE=2 \
    -DASSFUZZ_FONTCONFIG_SYSROOT="$FS" -I"$SRC/libass" \
    -c "$SRC/fuzz/fuzz.c" -o "$BUILD/fuzz.o"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/fuzz.o" "$BUILD/lsan_off.o" \
    "$BUILD/fuzz/libass/libass.a" $LIBS -lm -o /mayhem/libass_fuzzer
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/standalone_main.o" "$BUILD/fuzz.o" "$BUILD/lsan_off.o" \
    "$BUILD/fuzz/libass/libass.a" $LIBS -lm -o /mayhem/libass_fuzzer-standalone

# 5) Oracle build: libass with the project's NORMAL flags (no sanitizers, no -gdwarf-3), plus
#    upstream's standalone fuzz consumer (-o writes the parsed track in a canonical form) and the
#    known-answer probe mayhem/kat.c.
meson setup "$BUILD/test" "${MESON_COMMON[@]}" -Ddebug=true >/dev/null
ninja -C "$BUILD/test" -j"$MAYHEM_JOBS" libass/libass.a
TLIBS="$(PKG_CONFIG_PATH="$BUILD/test/meson-private" pkg-config --libs --static libass | sed 's/-lass\b//')"
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -I"$SRC/libass" "$SRC/fuzz/fuzz.c" "$SRC/fuzz/writeout.c" \
    "$BUILD/test/libass/libass.a" $TLIBS -lm -o "$BUILD/test/fuzz-standalone-tool"
# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -I"$SRC/libass" "$SRC/mayhem/kat.c" \
    "$BUILD/test/libass/libass.a" $TLIBS -lm -o "$BUILD/test/kat"

echo "build.sh: OK"
