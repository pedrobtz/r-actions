#!/usr/bin/env bash
# Builds alloc-failure.yml's interposer from the workflow itself and runs
# ordinary programs under it.
#
# The interposer shipped aborting every process that freed arena memory,
# with or without an injected failure: glibc's free() rejected the pointer
# at exit. Every swept run was then a "crash", so the job could only ever
# report its own bug. Nothing caught it because the source lives inside a
# YAML heredoc that nothing compiled until a consumer's weekly run.
#
# Extracting the source from the workflow, rather than keeping a copy here,
# is the point: a copy would pass while the shipped one stayed broken.
set -euo pipefail

workflow=".github/workflows/alloc-failure.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The heredoc body, with the step's indentation removed.
awk '
  /cat > failmalloc.c <<.CSRC./ { on = 1; next }
  on && /^[[:space:]]*CSRC[[:space:]]*$/ { exit }
  on { sub(/^          /, ""); print }
' "$workflow" > "$work/failmalloc.c"

if ! grep -q 'LD_PRELOAD\|dlsym' "$work/failmalloc.c"; then
  echo "::error::could not extract the interposer source from $workflow"
  exit 1
fi

gcc -shared -fPIC -O1 -Wall -Werror -o "$work/failmalloc.so" "$work/failmalloc.c" -ldl
echo "ok  interposer compiles"

fail=0
run() {
  local label="$1"; shift
  set +e
  "$@" >"$work/out" 2>&1
  local status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    echo "::error::$label exited $status under the interposer"
    sed -n '1,10p' "$work/out"
    fail=1
  else
    echo "ok  $label"
  fi
}

# No injection: the interposer must be invisible. perl frees arena memory at
# exit, which is what the shipped version aborted on.
run "perl, no injection" env LD_PRELOAD="$work/failmalloc.so" perl -e 1
run "sh, no injection"   env LD_PRELOAD="$work/failmalloc.so" sh -c true

# Counting must work, or the sweep has no range.
env LD_PRELOAD="$work/failmalloc.so" ALLOC_COUNT_FILE="$work/count" perl -e 1 || true
count="$(cat "$work/count" 2>/dev/null || echo 0)"
if [ "$count" -le 0 ]; then
  echo "::error::the interposer counted no allocations"
  fail=1
else
  echo "ok  counted $count allocations"
fi

# Injection must reach the program. The probe allocates in a loop, checks
# every result, and reports the first NULL through its exit status -- no
# stdio, whose buffer would be one more allocation. The count also includes
# the interposer's own fopen() at exit, so try the last few positions and
# expect one of them to land in the loop.
cat > "$work/probe.c" <<'CSRC'
#include <stdlib.h>
int main(void) {
  void *p[64];
  int i, missed = -1;
  for (i = 0; i < 64; i++) {
    p[i] = malloc(32);
    if (p[i] == NULL && missed < 0) missed = i;
  }
  for (i = 0; i < 64; i++) free(p[i]);
  return missed < 0 ? 100 : missed;
}
CSRC
gcc -O0 -o "$work/probe" "$work/probe.c"
set +e
env LD_PRELOAD="$work/failmalloc.so" ALLOC_COUNT_FILE="$work/pcount" "$work/probe"
set -e
total="$(cat "$work/pcount")"
hit=""
for n in $((total - 3)) $((total - 2)) $((total - 1)) "$total"; do
  set +e
  env LD_PRELOAD="$work/failmalloc.so" ALLOC_FAIL_AT="$n" "$work/probe"
  status=$?
  set -e
  if [ "$status" -lt 64 ]; then hit="$n (loop allocation #$status)"; break; fi
done
if [ -z "$hit" ]; then
  echo "::error::no ALLOC_FAIL_AT near the end of the probe ($total) failed its allocations"
  fail=1
else
  echo "ok  ALLOC_FAIL_AT=$hit returned NULL to the program"
fi

exit "$fail"
