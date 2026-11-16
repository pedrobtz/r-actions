#!/usr/bin/env bash
# fuzz.yml's keep-going mode end to end: the Fuzz step in fork mode on a
# target with two independent bugs, then the triage step. Stop-at-first would
# report one; keep-going must report both, as two findings, and fail the run
# although libFuzzer's fork mode exits 0. Needs clang with libFuzzer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/fuzz.yml" "$work" <<'PY'
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1]))["jobs"]["fuzz"]["steps"]
for sid, name in (("run", "fuzz.sh"), ("triage", "triage.sh")):
    open(f"{sys.argv[2]}/{name}", "w").write(next(s for s in steps if s.get("id") == sid)["run"])
PY

failed=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }

cd "$work"
clang -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=undefined \
  "$root/tests/fixtures/keep-going/harness.c" -o fuzz-target
mkdir corpus
# One seed a mutation away from each bug, neither crashing itself, so a short
# run finds both reliably: "OVx" overflows once it grows past 4 bytes, "SH"
# with a small shift once that byte reaches 32.
printf 'OVx' > corpus/ov; printf 'SH\001' > corpus/sh; printf 'zz' > corpus/zz
export UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1

set +e
env DICT="" MAX_TIME=30 EMBED_R=false EXTRA="" KEEP_GOING=true JOBS=2 \
  GITHUB_OUTPUT="$work/run.out" bash fuzz.sh > run.log 2>&1
status=$?
set -e
[ "$status" -ne 0 ] && ok "keep-going: the run fails when it saved inputs" || bad "keep-going: the run passed"
grep -q '^status=1' run.out && ok "keep-going: status is 1 though fork mode exits 0" || bad "keep-going: status [$(cat run.out)]"
n=$(ls -1 crash-* 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -ge 2 ] && ok "keep-going: the fuzzer went on past the first crash ($n inputs)" || bad "keep-going: $n saved input(s)"

env GITHUB_WORKSPACE="$root" GITHUB_OUTPUT="$work/triage.out" GITHUB_STEP_SUMMARY="$work/summary" \
  HARNESS=harness.c CFLAGS_IN="-g -O1" SANITIZERS=fuzzer,address,undefined EXTRA="" \
  EMBED_R=false MAX_FINDINGS=20 RUN_URL=https://run SHA=0123456789abcdef \
  bash triage.sh > triage.log 2>&1 || { cat triage.log; bad "triage failed"; }
findings=$(awk '/^findings<</{on=1; next} on && /^EOF_/{exit} on' triage.out)
kinds=$(printf '%s' "$findings" | python3 -c '
import json, sys
f = json.load(sys.stdin)
print(" ".join(sorted("ov" if "heap-buffer-overflow" in x["key"] else "sh" if "shift" in x["key"] else "?" for x in f)))')
[ "$kinds" = "ov sh" ] && ok "keep-going: both bugs reported, one finding each" || bad "keep-going findings: [$kinds]"
printf '%s' "$findings" | grep -q BuildId && bad "keep-going: a key carries the build's BuildId" || ok "keep-going: no key carries a BuildId"
cat summary

exit $failed
