#!/usr/bin/env bash
# rchk.yml's Run and Parse steps against the real image, on two fixtures with
# known answers: a package with an unprotected allocation, which must be
# reported and keyed, and one that does not compile, which must fail as
# "analysed nothing". Both directions matter: kalibera's January image built
# nothing for cpp11 packages and the job passed them as clean for months.
# Needs docker and network (the image and the packages' dependencies).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
# The container writes root-owned files into the mounted case directories, so
# on Linux a plain rm cannot remove them; remove them from inside the image.
cleanup() {
    rm -rf "$work" 2>/dev/null && return
    docker run --rm --entrypoint sh -v "$work:/w" "$image" -c 'rm -rf /w/* /w/.[!.]*' || true
    rm -rf "$work" || true
}
trap cleanup EXIT
image=${RCHK_IMAGE:-$(python3 - "$root/.github/workflows/rchk.yml" <<'PY'
import sys, yaml
on = yaml.safe_load(open(sys.argv[1]))
on = on.get(True) or on["on"]
print(on["workflow_call"]["inputs"]["image"]["default"])
PY
)}

python3 - "$root/.github/workflows/rchk.yml" "$work" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
job = next(v for k, v in jobs.items() if k != "changes")
for name, out in (("Run rchk in Docker", "run.sh"), ("Parse findings", "parse.sh")):
    open(f"{sys.argv[2]}/{out}", "w").write(next(s for s in job["steps"] if s.get("name") == name)["run"])
PY

failed=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }

run_case() {   # $1: fixture name; leaves the case directory in $dir
  dir="$work/$1"; mkdir -p "$dir"
  (cd "$dir" && R CMD build "$root/tests/fixtures/rchk/$1" >/dev/null && cp "$root/tests/fixtures/rchk/$1/DESCRIPTION" .)
  set +e
  (cd "$dir" && RCHK_IMAGE="$image" bash "$work/run.sh" > run.log 2>&1)
  status=$?
  set -e
}

docker pull --quiet "$image" >/dev/null

run_case buggypkg
[ "$status" -eq 0 ] && ok "a package rchk can build is analysed" || bad "buggypkg run failed: $(tail -3 "$dir/run.log")"
(cd "$dir" && bash "$work/parse.sh" >/dev/null 2>&1) || true
if grep -qx $'UP\tmake_pair\tsrc/bug.c' "$dir/findings.keys" 2>/dev/null; then
  ok "the unprotected allocation is reported and keyed"
else
  bad "the known PROTECT bug was not found: [$(cat "$dir/findings.keys" 2>/dev/null)]"
fi

run_case brokenpkg
[ "$status" -ne 0 ] && grep -q 'rchk analysed nothing' "$dir/run.log" \
  && ok "a package that does not build fails as analysed nothing" \
  || bad "brokenpkg: status $status, $(grep -m1 '::' "$dir/run.log" || echo 'no error line')"

exit $failed
