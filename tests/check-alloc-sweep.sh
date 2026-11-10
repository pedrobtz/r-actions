#!/usr/bin/env bash
# alloc-failure.yml's Sweep step on a scripted workload: which crashes fail
# the job. A crash the ignore-crash-pattern matches is listed apart and does
# not fail it; any other crash does. Getting this wrong either hides a
# package crash or keeps the job red for the interpreter's own bugs.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/alloc-failure.yml" "$work/sweep.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["alloc-failure"]["steps"] if s.get("id") == "sweep")
run = step["run"]
for k in ("floor", "total"):
    run = run.replace("${{ steps.range.outputs.%s }}" % k, "0")
open(sys.argv[2], "w").write(run)
PY

# Allocation 1 crashes in "base R", 2 crashes in "the package", 3 is fine.
cat > "$work/workload.sh" <<'W'
case "$ALLOC_FAIL_AT" in
  1) printf 'Traceback:\n 1: grepl("x", y)\n'; kill -SEGV $$ ;;
  2) printf 'Traceback:\n 1: .Call(C_perform, req)\n'; kill -SEGV $$ ;;
  *) echo ok ;;
esac
W

sweep() {   # sweep IGNORE: prints the sweep's exit status
  ( cd "$work" && rm -f crashes.txt foreign.txt silent.txt out.* && \
    env GITHUB_WORKSPACE="$work" GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY="$work/summary" \
      RUN_COMMAND="sh $work/workload.sh" EXPECT="" TARGET="" IGNORE="$1" MIN_HITS=0 \
      START=1 END=3 bash "$work/sweep.sh" > "$work/log" 2>&1; echo $? )
}
failed=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; cat "$work/log"; failed=1; fi; }

rc=$(sweep '^ 1: (grepl?|sub)\(')
check "the package's crash still fails the job" '[ "$rc" = 1 ]'
check "the base-R crash is listed apart" 'grep -q "allocation 1" "$work/foreign.txt"'
check "only the package's crash counts" 'grep -q "^crashes=1$" "$work/out" && ! grep -q "allocation 1" "$work/crashes.txt"'

sed -i.bak 's/^  2) .*$/  2) echo ok ;;/' "$work/workload.sh"
rc=$(sweep '^ 1: (grepl?|sub)\(')
check "a base-R crash alone passes" '[ "$rc" = 0 ] && grep -q "^foreign=1$" "$work/out"'
rc=$(sweep '')
check "with no pattern, every crash fails" '[ "$rc" = 1 ]'
exit $failed
