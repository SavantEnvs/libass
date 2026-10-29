#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# RUN the oracle binaries that mayhem/build.sh produced (normal flags, no sanitizers):
#   * mayhem/build/test/kat — parses an in-memory script and renders a vector drawing; its output is
#     compared to mayhem/test/expected/kat.out (parsed fields, bitmap position/size/colour).
#   * mayhem/build/test/fuzz-standalone-tool -o — upstream's fuzz consumer in write-out mode; the
#     canonical re-serialisation of each sample is diffed against a golden file. This covers the
#     ASS/SSA parser, SSA->ASS conversion, style/event handling.
# Every comparison is unconditional: a missing binary, missing output or empty output is a FAILURE.
BUILD="$SRC/mayhem/build/test"
EXP="$SRC/mayhem/test/expected"
SEEDS="$SRC/mayhem/libass_fuzzer/testsuite"
for b in kat fuzz-standalone-tool; do
  [ -x "$BUILD/$b" ] || { echo "missing $BUILD/$b (mayhem/build.sh should have built it)" >&2; emit_ctrf "libass-golden" 0 1 0; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
passed=0; failed=0

check() {  # check <name> <actual-file> <expected-file>
  if [ -s "$2" ] && diff -u "$3" "$2" >"$WORK/diff.txt" 2>&1; then
    echo "PASS $1"; passed=$((passed + 1))
  else
    echo "FAIL $1"; head -40 "$WORK/diff.txt" 2>/dev/null || true; failed=$((failed + 1))
  fi
}

"$BUILD/kat" > "$WORK/kat.out" 2>/dev/null || true
check kat "$WORK/kat.out" "$EXP/kat.out"

for s in styled.ass mixed.ssa drawing.ass sub1.ass; do
  rm -f "$WORK/$s.out"
  "$BUILD/fuzz-standalone-tool" -q -o "$WORK/$s.out" "$SEEDS/$s" >/dev/null 2>&1 || true
  check "writeout-$s" "$WORK/$s.out" "$EXP/$s.out"
done

emit_ctrf "libass-golden" "$passed" "$failed" 0
