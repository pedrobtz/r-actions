#!/usr/bin/env bash
# fuzz.yml's "Describe the finding" step and report.yml's issue logic, case
# by case. Both are shell inside YAML, and a wrong answer from either fails
# nothing visibly: a key that changes with line numbers opens a duplicate
# issue every night, and a report that closes a finding on a green run hides
# a bug the fuzzer simply did not reach again. The fixtures are trimmed from
# real nightly logs of November 2026.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

python3 - "$root/.github/workflows" "$work" <<'PY'
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
fuzz = yaml.safe_load(open(f"{wf}/fuzz.yml"))
step = next(s for s in fuzz["jobs"]["fuzz"]["steps"] if s.get("id") == "describe")
open(f"{out}/describe.sh", "w").write(step["run"])
report = yaml.safe_load(open(f"{wf}/report.yml"))
open(f"{out}/report.sh", "w").write(report["jobs"]["report"]["steps"][0]["run"])
PY

failed=0
ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; failed=1; }

# --- describe ---------------------------------------------------------------

describe() {   # $1: case directory holding fuzz.log; prints the outputs
  ( cd "$1" && env GITHUB_WORKSPACE=/home/runner/work/pkg/pkg \
      GITHUB_OUTPUT="$1/out" GITHUB_STEP_SUMMARY=/dev/null \
      HARNESS=tools/fuzz/fuzz_x.c CFLAGS_IN="-g -O1" \
      SANITIZERS=fuzzer,address,undefined RUN_URL=https://run SHA=0123456789abcdef \
      STATUS=1 bash "$work/describe.sh" >/dev/null )
}
output() { sed -n "s/^$2=//p" "$1/out"; }

fixture() {   # $1: name; stdin: fuzz.log
  mkdir -p "$work/$1"; cat > "$work/$1/fuzz.log"; echo "$work/$1"
}

d=$(fixture asan <<'LOG'
INFO: Seed: 12345
==2712==ERROR: AddressSanitizer: heap-use-after-free on address 0x50d002a67190 at pc 0x55 bp 0x7f sp 0x7f
READ of size 4 at 0x50d002a67190 thread T0
    #0 0x55 in node_qualified_tag_is /home/runner/work/pkg/pkg/src/vendor/gumbo/parser.c:756:17
Shadow bytes around the buggy address:
SUMMARY: AddressSanitizer: heap-use-after-free /home/runner/work/pkg/pkg/src/vendor/gumbo/parser.c:756:17 in node_qualified_tag_is
MS: 3 ShuffleBytes-InsertRepeatedBytes-CrossOver-; base unit: cbc6
LOG
)
printf 'abc' > "$d/crash-6fa6"; describe "$d"
f=$(output "$d" finding); k=$(output "$d" finding-key)
[ "$f" = "AddressSanitizer: heap-use-after-free src/vendor/gumbo/parser.c:756:17 in node_qualified_tag_is" ] \
  && ok "ASan: the finding is the SUMMARY, path relative" || bad "ASan finding: [$f]"
[ "$k" = "fuzz_x.c AddressSanitizer: heap-use-after-free parser.c in node_qualified_tag_is" ] \
  && ok "ASan: the key drops directories and line numbers" || bad "ASan key: [$k]"
grep -q 'YWJj' "$d/out" && ok "a small input is carried in the report" || bad "input missing from the report"
grep -q 'Shadow bytes' "$d/out" && bad "the excerpt runs into the shadow map" || ok "the excerpt stops before the shadow map"

d=$(fixture asan-moved < "$work/asan/fuzz.log"); sed -i.bak 's/756:17/802:9/g' "$d/fuzz.log"; describe "$d"
[ "$(output "$d" finding-key)" = "$k" ] && ok "the same bug on another line keeps its key" || bad "key changed with the line"

d=$(fixture ubsan <<'LOG'
src/zrd_walk.c:1222:49: runtime error: applying zero offset to null pointer
SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior src/zrd_walk.c:1222:49
LOG
); describe "$d"
f=$(output "$d" finding)
[ "$f" = "UndefinedBehaviorSanitizer: undefined-behavior src/zrd_walk.c:1222:49 (applying zero offset to null pointer)" ] \
  && ok "UBSan: the runtime error is named" || bad "UBSan finding: [$f]"

d=$(fixture timeout <<'LOG'
==6007== ERROR: libFuzzer: timeout after 26 seconds
SUMMARY: libFuzzer: timeout
LOG
); describe "$d"
[ "$(output "$d" finding)" = "libFuzzer: timeout" ] && ok "a hang is a timeout" || bad "timeout: [$(output "$d" finding)]"

d=$(fixture oom <<'LOG'
==2866== ERROR: libFuzzer: out-of-memory (used: 2147Mb; limit: 2048Mb)
LOG
); describe "$d"
[ "$(output "$d" finding)" = "libFuzzer: out-of-memory (used: 2147Mb; limit: 2048Mb)" ] \
  && ok "no SUMMARY: the ERROR line" || bad "oom: [$(output "$d" finding)]"
[ "$(output "$d" finding-key)" = "fuzz_x.c libFuzzer: out-of-memory (used: NMb; limit: NMb)" ] \
  && ok "memory figures do not change the key" || bad "oom key: [$(output "$d" finding-key)]"

d=$(fixture nothing <<'LOG'
INFO: Running with entropic power schedule
LOG
); describe "$d"
[ "$(output "$d" finding)" = "the fuzz target exited 1" ] && ok "an unrecognised log still names something" \
  || bad "fallback: [$(output "$d" finding)]"

# --- report -----------------------------------------------------------------

# `gh` answers issue list from $ISSUES (one "state number reason body" a line)
# and records every other call.
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "issue list" ]; then
  state=""; while [ $# -gt 0 ]; do [ "$1" = --state ] && state=$2; shift; done
  printf '%s\n' "$ISSUES" | while read -r s n r b; do
    [ "$s" = "$state" ] && [[ "$b" == *"$MARKER_WANT"* ]] && { echo "$n $r"; break; }
  done
  exit 0
fi
echo "$*" >> "$CALLS"
STUB
chmod +x "$work/bin/gh"

report() {   # $1 name, $2 result, $3 finding, $4 issues, $5 expected first call (regex)
  local calls="$work/calls"; : > "$calls"
  local key=${3:+$(printf '%s' "$3" | sha1sum | cut -c1-12)}
  env PATH="$work/bin:$PATH" CALLS="$calls" ISSUES="$4" \
    MARKER_WANT="r-actions:report:fuzz:${key:-run}" \
    GH_TOKEN=x REPO=o/r NAME=fuzz RESULT="$2" FINDING="$3" KEY="" DETAILS="details" \
    LABEL="" RUN=https://run SHA=0123456789 bash -c 'cd "$1" && bash report.sh' _ "$work" >/dev/null
  local got; got=$(grep -v "^label create" "$calls" | head -n 1 || true)
  if [[ "$got" =~ $5 ]]; then ok "$1"; else bad "$1: got [$got]"; fi
}

F="AddressSanitizer: heap-use-after-free x.c in f"
id=$(printf '%s' "$F" | sha1sum | cut -c1-12)
report "a new finding opens an issue"           failure "$F" ""                                                     '^issue create .*--title fuzz: AddressSanitizer'
report "a known finding gets a comment"         failure "$F" "open 7 null <!--r-actions:report:fuzz:$id-->"         '^issue comment 7 '
report "a fixed finding found again reopens"    failure "$F" "closed 7 COMPLETED <!--r-actions:report:fuzz:$id-->"  '^issue reopen 7 '
report "not planned stays closed"               failure "$F" "closed 7 NOT_PLANNED <!--r-actions:report:fuzz:$id-->" '^$'
report "another finding gets its own issue"     failure "$F" "open 7 null <!--r-actions:report:fuzz:000000000000-->" '^issue create '
report "green leaves a finding's issue open"    success "$F" "open 7 null <!--r-actions:report:fuzz:$id-->"         '^$'
report "a failure without a finding: one issue" failure ""   ""                                                     '^issue create .*--title Scheduled fuzz fails'
report "green closes the run's issue"           success ""   "open 9 null <!--r-actions:report:fuzz:run-->"         '^issue close 9 '

exit $failed
