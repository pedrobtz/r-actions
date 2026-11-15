#!/usr/bin/env bash
# analyzers.yml's "Turn the analyzer on" step, run for real on a fixture:
# src/own.c, src/vendor/lib.c and src/wrap.c (which #includes the vendored
# file) each hold a double free. With `skip` naming the vendored file and
# the wrapper, the analyzer must still report own.c and report nothing from
# the other two, which are compiled by the rule R's make uses, from inside
# src/, with the step's Makevars after the defaults. Also: a `skip` that
# covers every file fails, and one that matches nothing warns. Needs GCC
# with -fanalyzer (10 or later).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
CC=${CC:-gcc}

python3 - "$root/.github/workflows/analyzers.yml" "$work/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["fanalyzer"]["steps"] if s.get("name") == "Turn the analyzer on")
open(sys.argv[2], "w").write(step["run"])
PY

failed=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; failed=1; }

run_step() {   # run_step DIR SKIP: leaves DIR/makevars, DIR/out.log, DIR/rc
  local d=$1; rm -rf "$d"; mkdir -p "$d"; cp -R "$root/tests/fixtures/analyzers/src" "$d/"
  : > "$d/gh-output"
  local rc=0
  ( cd "$d" && R_MAKEVARS_USER="$d/makevars" GITHUB_OUTPUT="$d/gh-output" \
      ANALYZER_FLAGS=-fanalyzer SKIP="$2" bash "$work/step.sh" > "$d/out.log" 2>&1 ) || rc=$?
  echo "$rc" > "$d/rc"
}

# As R does: Makeconf's CFLAGS, then the user Makevars, and the suffix rule
# run from src/ so that objects are named relative to it.
build() {   # build DIR OBJECTS...
  local d=$1; shift
  printf 'CFLAGS = -O0\ninclude %s\n%%.o: %%.c\n\t$(CC) $(CFLAGS) -c $< -o $@\n' "$d/makevars" > "$d/Makefile"
  make -s -C "$d/src" -f "$d/Makefile" CC="$CC" "$@" > "$d/build.log" 2>&1
}

d="$work/skip"; run_step "$d" $'src/vendor\nsrc/wrap.c'
[ "$(cat "$d/rc")" = 0 ] && ok "skip: the step succeeds" || { fail "skip: exit $(cat "$d/rc")"; cat "$d/out.log"; }
grep -qxF 'vendor/lib.o: CFLAGS += -fno-analyzer' "$d/makevars" && ok "skip: a rule for the directory's file, named from src/" || fail "skip: no rule for vendor/lib.o"
grep -qxF 'wrap.o: CFLAGS += -fno-analyzer' "$d/makevars" && ok "skip: a rule for the wrapper" || fail "skip: no rule for wrap.o"
grep -q '^own.o' "$d/makevars" && fail "skip: own.o was skipped" || ok "skip: own.c keeps the analyzer"
grep -qxF 'skipped=2' "$d/gh-output" && ok "skip: two files counted" || fail "skip: count is $(cat "$d/gh-output")"
build "$d" own.o vendor/lib.o wrap.o
grep -q 'own.c.*\[-Wanalyzer-double-free\]' "$d/build.log" && ok "build: own.c is analysed" || { fail "build: no finding in own.c"; cat "$d/build.log"; }
grep -q 'lib.c.*\[-Wanalyzer' "$d/build.log" && { fail "build: vendor/lib.c was analysed"; cat "$d/build.log"; } || ok "build: vendor/lib.c and wrap.c are not"

# The control: with nothing skipped the vendored file is reported, so the
# absence above is the rule's doing.
d="$work/none"; run_step "$d" ""
build "$d" vendor/lib.o
grep -q 'lib.c.*\[-Wanalyzer-double-free\]' "$d/build.log" && ok "control: unskipped, vendor/lib.c is analysed" || { fail "control: no finding"; cat "$d/build.log"; }

d="$work/all"; run_step "$d" "src"
[ "$(cat "$d/rc")" = 1 ] && grep -q '::error::' "$d/out.log" && ok "all: skipping every file fails" || { fail "all: exit $(cat "$d/rc")"; cat "$d/out.log"; }

d="$work/miss"; run_step "$d" "src/nothere"
[ "$(cat "$d/rc")" = 0 ] && grep -q '::warning::' "$d/out.log" && ok "miss: a pattern matching nothing warns" || { fail "miss: exit $(cat "$d/rc")"; cat "$d/out.log"; }

exit "$failed"
