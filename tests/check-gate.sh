#!/usr/bin/env bash
# The `changes` gate's decisions, case by case: labels, profile and file
# rules. The gate is a shell script inside YAML, carried identically by every
# gated workflow, and a wrong answer either drops a check (a skip that should
# not happen) or wastes one -- neither of which fails anything visibly. This
# runs the copy in changes.yml with `gh` stubbed to list the given files.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

python3 - "$root/.github/workflows/changes.yml" "$work/gate.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write(doc["jobs"]["changes"]["steps"][0]["run"])
PY

cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# `gh api .../compare/...` with --jq: the count, then one path per line.
set -f
printf '%s\n' "$(wc -w <<<"$FILES" | tr -d ' ')" $FILES
STUB
chmod +x "$work/bin/gh"

failed=0
# case <name> <expected outputs> <event> <labels JSON> <workflow> <profile>
#      <files> [workflow_ref] [file rules]
case_() {
  local name=$1 want=$2 out
  out=$(mktemp -p "$work")
  env PATH="$work/bin:$PATH" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY=/dev/null \
    REPO=o/r EVENT="$3" LABELS="$4" R_ACTIONS_WORKFLOW="$5" R_ACTIONS_PROFILE="$6" \
    FILES="$7" WORKFLOW_REF="${8:-o/r/.github/workflows/native-checks.yaml@refs/pull/1/merge}" \
    FILE_RULES="${9:-true}" PR_BASE=a PR_HEAD=b BEFORE=c AFTER=d FORCED=false \
    bash "$work/gate.sh" >/dev/null 2>&1
  local got; got=$(tr '\n' ' ' <"$out" | sed 's/ $//')
  if [ "$got" = "$want" ]; then echo "ok   $name"
  else echo "FAIL $name: got [$got], want [$want]"; failed=1; fi
}

R=R/x.R C=src/a.c
case_ "pull request, auto: quick"           "docs-only=false scope=code profile=quick" pull_request '[]' fuzz auto "$R"
case_ "pull request, auto, full-ci: full"   "docs-only=false scope=code profile=full"  pull_request '["full-ci"]' fuzz auto "$R"
case_ "push, auto: full"                    "docs-only=false scope=code profile=full"  push null fuzz auto "$R"
case_ "push, explicit quick stays quick"    "docs-only=false scope=code profile=quick" push null fuzz quick "$R"
case_ "no profile input: full"              "docs-only=false scope=code profile=full"  pull_request '[]' fuzz "" "$R"
case_ "skip-ci:fuzz skips fuzz"             "docs-only=true scope=docs profile=full"   pull_request '["skip-ci:fuzz"]' fuzz "" "$C"
case_ "skip-ci:fuzz leaves lto alone"       "docs-only=false scope=code profile=full"  pull_request '["skip-ci:fuzz"]' lto "" "$C"
case_ "ci:minimal: one quick check"         "docs-only=true scope=metadata profile=quick" pull_request '["ci:minimal"]' r-cmd-check auto "$C"
case_ "full-ci overrides skip labels"       "docs-only=false scope=code profile=full"  pull_request '["skip-ci:fuzz","ci:minimal","full-ci"]' fuzz auto "$C"
case_ "labels are ignored on push"          "docs-only=false scope=code profile=full"  push '["skip-ci:fuzz"]' fuzz "" "$C"
case_ "a label must match exactly"          "docs-only=false scope=code profile=full"  pull_request '["skip-ci:fuzz-hour","good first issue"]' fuzz "" "$C"
case_ "housekeeping files are docs"         "docs-only=true scope=docs profile=full"   pull_request '[]' fuzz "" "CRAN-SUBMISSION .gitignore .github/workflows/cran-release.yaml"
case_ "the caller's own workflow is code"   "docs-only=false scope=code profile=full"  pull_request '[]' fuzz "" "CRAN-SUBMISSION .github/workflows/native-checks.yaml"
case_ "unreadable workflow_ref: wf is code" "docs-only=false scope=code profile=full"  pull_request '[]' fuzz "" ".github/workflows/x.yaml" "weird"
case_ ".Rbuildignore is code"               "docs-only=false scope=code profile=full"  pull_request '[]' fuzz "" ".Rbuildignore"
case_ "DESCRIPTION + CRAN-SUBMISSION: meta" "docs-only=true scope=metadata profile=full" pull_request '[]' fuzz "" "DESCRIPTION CRAN-SUBMISSION"
case_ "file rules off: docs change runs"    "docs-only=false scope=code profile=full"  pull_request '[]' fuzz "" "README.md" "" false
case_ "file rules off: a label still skips" "docs-only=true scope=docs profile=full"   pull_request '["skip-ci:fuzz"]' fuzz "" "$C" "" false

exit "$failed"
