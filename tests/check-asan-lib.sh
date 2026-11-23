#!/usr/bin/env bash
# sanitizers.yml's asan job: the library the package is installed into must
# not be inside the checkout. The default run does `R CMD build .`, which
# ships whatever .Rbuildignore does not exclude, so a library under the
# checkout went into the tarball: R CMD check NOTEd "not a source package"
# on every caller and failed decimal with an ERROR, its installed help
# having Summary+2edecimal.html and summary+2edecimal.html (2026-11-16).
#
# Runs the job's real install, verify and run steps (by id) against a stub
# `R` and `nm`, once as configured and once with the library moved back
# into the checkout, which must fail.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

python3 - "$root/.github/workflows/sanitizers.yml" "$work" <<'PY'
import sys, yaml
wf, out = sys.argv[1], sys.argv[2]
job = yaml.safe_load(open(wf))["jobs"]["asan"]
open(f"{out}/asan-lib", "w").write(job["env"]["ASAN_LIB"])
for sid in ("asan-install", "asan-verify", "asan-run"):
    step = next(s for s in job["steps"] if s.get("id") == sid)
    open(f"{out}/{sid}.sh", "w").write(step["run"])
PY

failed=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; failed=1; }

# A stub R: INSTALL leaves an instrumented-looking shared object in the
# library, build records what it would have shipped, check records the
# library it was given.
cat > "$work/bin/R" <<'SH'
#!/bin/sh
[ "$1" = CMD ] || exit 2
case "$2" in
  INSTALL)
    for a in "$@"; do case "$a" in --library=*) lib=${a#--library=} ;; esac; done
    mkdir -p "$lib/fakepkg/libs" && : > "$lib/fakepkg/libs/fakepkg.so" ;;
  build)
    find . -mindepth 1 -not -path './.git*' | sort > "$RECORD/shipped"
    : > fakepkg_1.0.tar.gz ;;
  check)
    echo "$R_LIBS" > "$RECORD/r_libs"
    mkdir -p fakepkg.Rcheck; echo "Status: OK" ;;
esac
SH
cat > "$work/bin/nm" <<'SH'
#!/bin/sh
echo "                 U __asan_init"
SH
chmod +x "$work/bin/R" "$work/bin/nm"

run_job() {   # $1: case name, $2: ASAN_LIB; runs the three steps in a fresh package
  local pkg="$work/$1/pkg"
  mkdir -p "$pkg/src" "$pkg/R" "$work/$1/record"
  echo "Package: fakepkg" > "$pkg/DESCRIPTION"
  ( cd "$pkg" && export PATH="$work/bin:$PATH" GITHUB_WORKSPACE="$pkg" \
      ASAN_LIB="$2" RECORD="$work/$1/record" SUPPRESSIONS= RUN_COMMAND= \
    && bash "$work/asan-install.sh" && bash "$work/asan-verify.sh" \
    && bash "$work/asan-run.sh" ) > "$work/$1/log" 2>&1
}

shipped_lib() {   # $1: case name, $2: library; true if the tarball held any of it
  local rel
  rel=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
        "$2" "$work/$1/pkg")
  case "$rel" in ../*) return 1 ;; esac
  grep -qx "./$rel\(/.*\)\?" "$work/$1/record/shipped"
}

# --- as configured -------------------------------------------------------

lib=$(cat "$work/asan-lib")
case "$lib" in
  /*) ok "ASAN_LIB is an absolute path ($lib)" ;;
  *)  bad "ASAN_LIB is not absolute: $lib (it would resolve inside the checkout)" ;;
esac
case "$lib" in
  *'${{'*|*GITHUB_WORKSPACE*|*github.workspace*)
    bad "ASAN_LIB names the workspace: $lib" ;;
  *) ok "ASAN_LIB does not name the workspace" ;;
esac

# Run the configured shape with the library under this test's own directory,
# so the test writes nothing to the real /tmp path.
if run_job configured "$work/asan-lib-dir"; then
  ok "install, verify and run succeed with the library outside the checkout"
else
  bad "the steps failed as configured"; sed 's/^/     /' "$work/configured/log"
fi
if shipped_lib configured "$work/asan-lib-dir"; then
  bad "the tarball shipped the library"
else
  ok "the tarball did not ship the library"
fi
if [ "$(cat "$work/configured/record/r_libs" 2>/dev/null)" = "$work/asan-lib-dir" ]; then
  ok "R CMD check ran with R_LIBS set to the library"
else
  bad "R CMD check saw R_LIBS=$(cat "$work/configured/record/r_libs" 2>/dev/null)"
fi
grep -q "ok: ASan runtime is referenced" "$work/configured/log" \
  && ok "verify found the installed shared object" \
  || bad "verify did not find the installed shared object"

# --- the bug, reintroduced: the library back inside the checkout ---------

run_job inside "$work/inside/pkg/lib" || true
if shipped_lib inside "$work/inside/pkg/lib"; then
  ok "a library inside the checkout is detected as shipped (the check can fail)"
else
  bad "a library inside the checkout was not detected; this test proves nothing"
fi

exit "$failed"
