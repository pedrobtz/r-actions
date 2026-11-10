#!/usr/bin/env bash
# assurance.yml's check, case by case. A checker that passes a claim nothing
# backs is worse than none: the file then says a package is covered where
# it is not. Each case is a package tree with an assurance file and
# workflows, and the result the check must give.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/assurance.yml" "$work/check.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["assurance"]["steps"] if s.get("id") == "check")
open(sys.argv[2], "w").write(step["run"])
PY

failed=0
# case NAME WANT(0|1) PATTERN: runs the check in $work/NAME; PATTERN must
# appear in its output (an empty pattern skips that).
case_() {
  local name=$1 want=$2 pat=$3 out rc=0
  out=$(cd "$work/$name" && bash "$work/check.sh" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name: exit $rc, want $want"; echo "$out" | sed 's/^/     /'; failed=1
  elif [ -n "$pat" ] && ! grep -q -- "$pat" <<<"$out"; then
    echo "FAIL $name: no \`$pat\` in"; echo "$out" | sed 's/^/     /'; failed=1
  else
    echo "ok   $name"
  fi
}
pkg() {   # pkg NAME: an empty package with the native-checks caller; stdin is the file
  mkdir -p "$work/$1/.agents" "$work/$1/.github/workflows"
  cat > "$work/$1/.agents/assurance.md"
  cat > "$work/$1/.github/workflows/native-checks.yaml" <<'Y'
jobs:
  sanitizers: {uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1}
  valgrind: {uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@v1}
  rchk: {uses: pedrobtz/r-actions/.github/workflows/rchk.yml@v1}
  gctorture: {uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1}
  analyzers: {uses: pedrobtz/r-actions/.github/workflows/analyzers.yml@v1}
Y
}
checks_compiled='| sanitizers | done | native-checks.yaml |
| valgrind | done | native-checks.yaml |
| rchk | done | native-checks.yaml |
| gctorture | done | native-checks.yaml |
| analyzers | done | native-checks.yaml |
| alloc-failure | gap #12 | |
| mutation | n/a: no C tests outside R | |'

pkg good <<EOF2
## Kinds

\`compiled\` \`untrusted-input\` \`lifecycle\`

## Required checks

| Check | Status | Where |
|---|---|---|
$checks_compiled
| fuzz | done | fuzz.yaml (own) |
| fuzz-reach | gap #13 | |

## Boundaries

| Boundary | Oracle | Carried by |
|---|---|---|
| gzip | round trip, and zlib decoding what we encode | tests/testthat/test-gzip.R |
| gzip, two members | the concatenation | gap #14 |

## Objects

| Object | Sequences | Fork | Unwind | Owner |
|---|---|---|---|---|
| stream | fuzz/fuzz_stream.c | test-fork.R | test-unwind.R | n/a: borrows nothing |

## Limits

| Limit | Unit | Straddled by |
|---|---|---|
| max_size | decoded bytes | test-limits.R |
EOF2
echo 'jobs: {}' > "$work/good/.github/workflows/fuzz.yaml"
case_ good 0 "2 tracked gaps; 0 problems"

mkdir -p "$work/missing"; case_ missing 1 "does not exist"

pkg badkind <<'EOF2'
## Kinds

`compiled` `parser`

## Required checks

| Check | Status | Where |
|---|---|---|
EOF2
case_ badkind 1 '`parser` is not a kind'
case_ badkind 1 'no row for `rchk`, which `compiled` requires'

pkg nobacking <<EOF2
## Kinds

\`compiled\`

## Required checks

| Check | Status | Where |
|---|---|---|
$(sed 's/| alloc-failure | gap #12 | |/| alloc-failure | done | native-checks.yaml |/' <<<"$checks_compiled")
EOF2
case_ nobacking 1 'does not call alloc-failure.yml'

pkg nofile <<EOF2
## Kinds

\`compiled\`

## Required checks

| Check | Status | Where |
|---|---|---|
$(sed 's/| alloc-failure | gap #12 | |/| alloc-failure | done | memory.yaml |/' <<<"$checks_compiled")
EOF2
case_ nofile 1 '`memory.yaml` is not a file'

pkg untracked <<EOF2
## Kinds

\`compiled\`

## Required checks

| Check | Status | Where |
|---|---|---|
$(sed 's/| alloc-failure | gap #12 | |/| alloc-failure | gap | |/; s/| mutation | n\/a: no C tests outside R | |/| mutation | n\/a | |/' <<<"$checks_compiled")
EOF2
case_ untracked 1 'a gap without an issue'
case_ untracked 1 'needs a reason'

pkg notable <<'EOF2'
## Kinds

`lifecycle` `spec`

## Required checks

| Check | Status | Where |
|---|---|---|
EOF2
case_ notable 1 '## Boundaries: required by `spec`'
case_ notable 1 '## Objects: required by `lifecycle`'

pkg nooracle <<'EOF2'
## Kinds

`emits`

## Boundaries

| Boundary | Oracle | Carried by |
|---|---|---|
| upload | no crash under ASan | fuzz/fuzz_engine.c |
| download | | test-download.R |
| redirect | coverage of redirect.c | |
EOF2
case_ nooracle 1 '`no crash under ASan` is not an oracle'
case_ nooracle 1 'row 2 (download), Oracle: empty'
case_ nooracle 1 'row 3 (redirect), Carried by: empty'
case_ nooracle 1 '`coverage of redirect.c` is not an oracle'

exit $failed
