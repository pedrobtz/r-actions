#!/usr/bin/env bash
# assurance.yml's gating step, case by case. Each case is a package's
# .github/workflows, the mode, and the result the step must give. A check
# that passes an ungated job is the failure this exists to catch: zuhttp ran
# eight real jobs on a pull request that changed one Markdown file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/assurance.yml" "$work/gating.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in wf["jobs"]["assurance"]["steps"] if s.get("id") == "gating")
open(sys.argv[2], "w").write(step["run"])
PY

failed=0
# case NAME MODE WANT PATTERN: the step in $work/NAME; PATTERN must appear in
# its output (`!PATTERN`: must not).
case_() {
  local name=$1 mode=$2 want=$3 pat=$4 out rc=0
  out=$(cd "$work/$name" && UNGATED_JOBS=$mode bash "$work/gating.sh" 2>&1) || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL $name ($mode): exit $rc, want $want"; echo "$out" | sed 's/^/     /'; failed=1
  elif [ "${pat#!}" != "$pat" ] && grep -q -- "${pat#!}" <<<"$out"; then
    echo "FAIL $name ($mode): \`${pat#!}\` in"; echo "$out" | sed 's/^/     /'; failed=1
  elif [ "${pat#!}" = "$pat" ] && [ -n "$pat" ] && ! grep -q -- "$pat" <<<"$out"; then
    echo "FAIL $name ($mode): no \`$pat\` in"; echo "$out" | sed 's/^/     /'; failed=1
  else
    echo "ok   $name ($mode)"
  fi
}
wf() {   # wf CASE FILE: stdin is the workflow
  mkdir -p "$work/$1/.github/workflows"
  cat > "$work/$1/.github/workflows/$2"
}

# Gated every way ci.md allows: a gated r-actions call, the changes job, a
# job wired to it, a schedule-only job, an opt-out with a reason, a `paths`
# filter, and the exempt pkgdown and coverage workflows.
wf clean own.yaml <<'Y'
on: {pull_request: {}, schedule: [{cron: '0 0 * * 0'}]}
jobs:
  changes:
    uses: pedrobtz/r-actions/.github/workflows/changes.yml@v1
  check:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
  ctest:
    needs: changes
    if: ${{ !cancelled() && needs.changes.outputs.docs-only != 'true' }}
    runs-on: ubuntu-latest
    steps: [{run: make}]
  soak:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps: [{run: make soak}]
  # ungated: lints the Markdown itself
  prose:
    runs-on: ubuntu-latest
    steps: [{run: true}]
Y
wf clean vendor.yaml <<'Y'
on: {pull_request: {paths: ['src/vendor/**']}}
jobs:
  verify: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
wf clean pkgdown.yaml <<'Y'
on: [pull_request]
jobs:
  pkgdown: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
wf clean coverage.yaml <<'Y'
on: pull_request
jobs:
  coverage: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
case_ clean warn 0 "0 ungated jobs"
case_ clean fail 0 "0 ungated jobs"

# zuhttp's conventions.yaml: a plain job on every pull request.
wf plain conventions.yaml <<'Y'
on:
  pull_request:
jobs:
  air-format:
    runs-on: ubuntu-latest
    steps: [{run: air format --check .}]
Y
case_ plain warn 0 "::warning file=.github/workflows/conventions.yaml,line=4::job \`air-format\`"
case_ plain fail 1 "::error file=.github/workflows/conventions.yaml,line=4::job \`air-format\`"

# needs: changes without testing docs-only still runs on documentation.
wf needsonly own.yaml <<'Y'
on: pull_request
jobs:
  changes: {uses: pedrobtz/r-actions/.github/workflows/changes.yml@v1}
  ctest: {needs: changes, runs-on: ubuntu-latest, steps: [{run: make}]}
Y
case_ needsonly fail 1 "job \`ctest\`"

# An opt-out comment with no reason is not one.
wf noreason own.yaml <<'Y'
on: pull_request
jobs:
  # ungated:
  lint: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
case_ noreason fail 1 "job \`lint\`"

# A job that also runs on pull_request under its event test is still ungated.
wf eventpr own.yaml <<'Y'
on: [pull_request, push]
jobs:
  build:
    if: github.event_name == 'push' || github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps: [{run: true}]
Y
case_ eventpr fail 1 "job \`build\`"

# paths-ignore is a finding of its own; push-only workflows are not checked.
wf ignore native.yaml <<'Y'
on: {pull_request: {paths-ignore: ['**.md']}}
jobs:
  build: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
wf ignore release.yaml <<'Y'
on: {push: {branches: [main]}}
jobs:
  tag: {runs-on: ubuntu-latest, steps: [{run: true}]}
Y
case_ ignore fail 1 "gates with \`paths-ignore\`"
case_ ignore fail 1 "!release.yaml"

# The mode is checked, not read as the weaker one.
case_ clean loose 1 "ungated-jobs must be warn or fail"

exit $failed
