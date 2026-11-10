#!/usr/bin/env bash
# fuzz.yml's "Fuzz reach" step and mutation.yml's steps, run for real on a
# fixture: a library with one function the fuzz harness and the test reach,
# a condition they take one way only, and one function nothing calls. Both
# reports fail nothing on their own when wrong -- a reach table that lists
# no files, or a mutation summary of zero mutants, still exits 0 -- so the
# fixture's known answer is the check. Needs clang with libFuzzer (and, for
# the mutation half, the apt access that installs Mull): CI only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fx="$root/tests/fixtures/native"
part=${1:-all}

python3 - "$root/.github/workflows" "$work" <<'PY'
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
fuzz = yaml.safe_load(open(f"{wf}/fuzz.yml"))
step = next(s for s in fuzz["jobs"]["fuzz"]["steps"] if s.get("name") == "Fuzz reach")
open(f"{out}/reach.sh", "w").write(step["run"])
mut = yaml.safe_load(open(f"{wf}/mutation.yml"))
for s in mut["jobs"]["mutation"]["steps"]:
    if "name" in s:
        open(f"{out}/mut-{s['name'].split()[0].lower()}.sh", "w").write(s["run"])
PY

failed=0
want() {   # want FILE PATTERN WHAT
  if grep -q -- "$2" "$1"; then echo "ok   $3"; else echo "FAIL $3: no \`$2\` in $1"; sed 's/^/     /' "$1"; failed=1; fi
}

if [ "$part" = all ] || [ "$part" = reach ]; then
  d="$work/reach"; mkdir -p "$d/corpus" "$d/src"
  cp "$fx/lib.c" "$d/src/"; cp "$fx/harness.c" "$d/"
  printf 'A' > "$d/corpus/a"; printf '\x07' > "$d/corpus/b"
  echo src/lib.c > "$d/sources.txt"
  run_reach() {   # $1: floor; prints nothing, leaves fuzz-reach.txt and the status
    ( cd "$d" && env GITHUB_WORKSPACE="$d" GITHUB_STEP_SUMMARY="$d/summary.md" \
        HARNESS=harness.c CFLAGS_IN="-g -O1" EMBED_R=false FLOOR="$1" \
        bash "$work/reach.sh" > "$d/out.log" 2>&1 )
  }
  rc=0; run_reach 0 || rc=$?
  [ "$rc" = 0 ] && echo "ok   reach: floor 0 passes" || { echo "FAIL reach: exit $rc at floor 0"; cat "$d/out.log"; failed=1; }
  want "$d/fuzz-reach.txt" '^| `src/lib.c` |' "reach: the source file is in the table"
  want "$d/fuzz-reach.txt" '^src/lib.c:12 lib_unused$' "reach: the function nothing calls is listed"
  want "$d/fuzz-reach.txt" '^src/lib.c: 5' "reach: the one-sided condition on line 5 is listed"
  want "$d/summary.md" 'Functions no input enters' "reach: the summary carries the function list"
  rc=0; run_reach 99 || rc=$?
  [ "$rc" = 1 ] && echo "ok   reach: floor 99 fails" || { echo "FAIL reach: exit $rc at floor 99, want 1"; failed=1; }
fi

if [ "$part" = all ] || [ "$part" = mutation ]; then
  d="$work/mut"; mkdir -p "$d/src"
  cp "$fx/lib.c" "$d/src/"; cp "$fx/test.c" "$d/"
  envf="$d/env"; : > "$envf"
  ( cd "$d" && GITHUB_ENV="$envf" RUNNER_TEMP="$d" LLVM=18 MULL=0.35.0 bash "$work/mut-install.sh" )
  while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}=${kv#*=}"; done < "$envf"
  ( cd "$d" && GITHUB_ENV="$envf" RUNNER_TEMP="$d" INCLUDE="" EXCLUDE=".*/test\.c" TIMEOUT=10000 \
      MUTATORS=$'cxx_gt_to_ge\ncxx_gt_to_le' \
      BUILD='$MULL_CC -c src/lib.c -o lib.o && $MULL_CC -c test.c -o test.o && $MULL_CC lib.o test.o -o mtest' bash "$work/mut-configure.sh" )
  while IFS= read -r kv; do [ -n "$kv" ] && export "${kv%%=*}=${kv#*=}"; done < "$envf"
  ( cd "$d" && RUNNER_TEMP="$d" TESTS=mtest bash "$work/mut-run.sh" > "$d/run.log" 2>&1 )
  ( cd "$d" && GITHUB_WORKSPACE="$d" GITHUB_STEP_SUMMARY="$d/summary.md" bash "$work/mut-report.sh" > /dev/null )
  want "$d/survivors.txt" '^src/lib.c:4:' "mutation: a mutant of the untested \`> 100\` branch survives"
  want "$d/killed.txt" '^src/lib.c:6:' "mutation: a mutant of the tested \`> 0\` comparison is killed"
  want "$d/summary.md" '| `src/lib.c` |' "mutation: the summary has the per-file row"
fi
exit $failed
