#!/usr/bin/env bash
# The vendor guard's PR step, case by case. It is a shell script inside YAML,
# and it fails in both directions without anyone noticing: a rule that cannot
# be met (a legitimate patch edit goes red, people learn to ignore the job),
# or one met too easily (a hand edit to vendored code goes green). This runs
# the copy in vendor.yml against throwaway repositories, each with a real
# origin and a pull-request branch, so its fetch and three-dot diff run as
# they do on a runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

python3 - "$root/.github/workflows/vendor.yml" "$work/guard.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
steps = doc["jobs"]["vendor"]["steps"]
step = next(s for s in steps if s.get("name") == "Vendored changes must update the manifest")
open(sys.argv[2], "w").write(step["run"])
PY

DEFAULT=$'tools/vendor/manifest.tsv\ntools/vendor/checksums.sha256'
ALT=$'tools/vendor/manifest.tsv | tools/patches/\ntools/vendor/checksums.sha256'

fails=0
n=0
# case NAME WANT(0|1) MUST_UPDATE FILE...: a PR branch that changes FILEs.
case_() {
  local name=$1 want=$2 must=$3; shift 3
  n=$((n + 1))
  local dir="$work/$n"
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/repo" 2>/dev/null
  (
    cd "$dir/repo"
    git config user.email t@example.com; git config user.name t
    git checkout -q -b main
    mkdir -p src/vendor tools/vendor tools/patches/lib
    for f in src/vendor/lib.c tools/vendor/manifest.tsv \
             tools/vendor/checksums.sha256 tools/patches/lib/0001.patch; do
      echo base > "$f"
    done
    git add -A; git commit -q -m base; git push -q origin main
    git checkout -q -b pr
    for f in "$@"; do mkdir -p "$(dirname "$f")"; echo changed >> "$f"; done
    git add -A; git commit -q -m pr
  )
  local rc=0
  (cd "$dir/repo" && BASE_REF=main PATHS="" VENDOR_DIR=src/vendor \
     MUST_UPDATE="$must" bash -eu "$work/guard.sh") > "$dir/out" 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then
    echo "ok    $name"
  else
    echo "FAIL  $name: exit $rc, want $want"; sed 's/^/      /' "$dir/out"
    fails=$((fails + 1))
  fi
}

case_ "no vendored change"                 0 "$DEFAULT" R/a.R
case_ "default: manifest and checksums"    0 "$DEFAULT" src/vendor/lib.c tools/vendor/manifest.tsv tools/vendor/checksums.sha256
case_ "default: no checksums"              1 "$DEFAULT" src/vendor/lib.c tools/vendor/manifest.tsv
case_ "default: patch edit is not enough"  1 "$DEFAULT" src/vendor/lib.c tools/patches/lib/0001.patch tools/vendor/checksums.sha256
case_ "alt: patch edit meets the manifest" 0 "$ALT"     src/vendor/lib.c tools/patches/lib/0001.patch tools/vendor/checksums.sha256
case_ "alt: manifest still meets it"       0 "$ALT"     src/vendor/lib.c tools/vendor/manifest.tsv tools/vendor/checksums.sha256
case_ "alt: neither alternative"           1 "$ALT"     src/vendor/lib.c tools/vendor/checksums.sha256
case_ "alt: still needs the checksums"     1 "$ALT"     src/vendor/lib.c tools/patches/lib/0001.patch
case_ "alt: a prefix, not a substring"     1 "$ALT"     src/vendor/lib.c x/tools/patches/a tools/vendor/checksums.sha256
case_ "alt: a directory, not a sibling"    1 "$ALT"     src/vendor/lib.c tools/patches-old/a tools/vendor/checksums.sha256
case_ "alt: a dot is a dot"                1 "$ALT"     src/vendor/lib.c tools/vendor/manifestXtsv tools/vendor/checksums.sha256

if [ "$fails" -ne 0 ]; then
  echo "$fails of $n cases failed"; exit 1
fi
echo "all $n cases passed"
