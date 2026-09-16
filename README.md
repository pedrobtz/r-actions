# r-actions

Reusable GitHub Actions workflows for R packages. `r-cmd-check.yml` is the
standard `R CMD check`, run across the GitHub runners *and* the CRAN-like
containers that an ordinary [r-lib/actions](https://github.com/r-lib/actions)
matrix cannot reach. The rest cover test coverage, memory safety, undefined
behaviour, and static analysis.

## Versioning

Workflows are released under [semantic versioning](https://semver.org/). Pin
consumers to a major-version tag (e.g. `@v1`) to receive backwards-compatible
updates automatically, or to an exact tag (e.g. `@v1.0.0`) to lock a specific
release. Avoid `@main`—it tracks the development tip and may contain breaking
changes.

See [Releases](https://github.com/pedrobtz/r-actions/releases) for the full
changelog.

## Workflows

### `r-cmd-check.yml` — R CMD check, runners and CRAN-like containers

The standard check, in one workflow, across both the GitHub-hosted runners and
the R-hub containers built to match CRAN's r-devel Linux flavors. Fails on a
WARNING on every leg.

```yaml
jobs:
  R-CMD-check:
    uses: pedrobtz/r-actions/.github/workflows/r-cmd-check.yml@v1
```

Two jobs, covering the two halves of CRAN's
[flavor list](https://cran.r-project.org/web/checks/check_flavors.html):

| Job | Legs | CRAN flavors |
|---|---|---|
| `runners` | macOS, Windows, Ubuntu release + oldrel-1 | the macOS, Windows and release/oldrel Linux flavors |
| `containers` | `ubuntu-clang`, `ubuntu-gcc16` | `r-devel-linux-x86_64-debian-clang`, `r-devel-linux-x86_64-debian-gcc` |

The `containers` job is the part an ordinary matrix cannot do. Those two
flavors differ from any GitHub runner in the **compiler**: clang 23 building C
as `-std=gnu23`, and GCC 16. `ubuntu-latest` carries neither — its clang still
defaults to C17 and its GCC is several majors behind — so a diagnostic that
exists only in the newer compiler, or only in the newer language standard,
stays invisible until CRAN's incoming pretest reports it. That is a rejected
submission rather than a red check.

It matters most for a package that compiles bundled third-party C. Upstream
code is written against the compilers upstream tests on, and the gap arrives
as someone else's warnings in your check log.

**The default `runners` matrix has no R-devel Linux row**, unlike the standard
r-lib/actions template. The `containers` job is R-devel on Linux already, on
the compilers CRAN actually uses; a row pinning R-devel to the runner's own
GCC matches no CRAN flavor. Add it back if you want a plain R-devel leg as
insurance against a stale container image.

Every container run logs the image's `CC`, `CXX`, flags and resulting
`__STDC_VERSION__` before checking, so "is this image really the flavor I
think it is?" is answerable from the log rather than from a debugging round
trip.

Optional inputs:

```yaml
    with:
      containers: '["ubuntu-clang", "ubuntu-gcc16"]'   # default; '[]' skips the job
      runners: |                                       # default
        [{"os": "macos-latest", "r": "release"},
         {"os": "windows-latest", "r": "release"},
         {"os": "ubuntu-latest", "r": "release"},
         {"os": "ubuntu-latest", "r": "oldrel-1"}]
      args: 'c("--no-manual", "--as-cran")'            # default
      build-args: 'c("--no-manual")'                   # default, runners only
      timeout-minutes: 45                              # default
      env: |                                           # extra env for the check steps
        MYPKG_SLOW_TESTS=true
```

`containers` takes any name from <https://r-hub.github.io/containers/>.
`ubuntu-next` and `ubuntu-release` are CRAN-like too, but sit closer to what
the `runners` job already does. `build-args` reaches the `runners` job only:
the container images carry no LaTeX and no vignette-compaction tooling.

### `coverage.yml` — Test coverage

Measures test coverage with [covr](https://covr.r-lib.org/), writes a
per-file breakdown to the job summary, and commits a self-hosted SVG badge to
`.github/badges/coverage.svg` on every push to `main`/`master` (avoiding
external badge services). The badge colour thresholds are: green ≥ 90 %,
yellow ≥ 75 %, orange ≥ 60 %, red below 60 %.

> **Note:** this workflow commits back to the repository, so the caller must
> grant `contents: write`.

```yaml
jobs:
  coverage:
    uses: pedrobtz/r-actions/.github/workflows/coverage.yml@v1
    permissions:
      contents: write
```

To display the badge in your README, add the following line (replacing
`{owner}/{repo}` with your repository):

```markdown
![Coverage]({owner}/{repo}/raw/main/.github/badges/coverage.svg)
```

### `sanitizers.yml` — UndefinedBehaviorSanitizer

Builds and checks the package under R-devel with clang and UBSan, catching
signed integer overflow, misaligned pointers, invalid casts and similar. The
job **halts** on a finding, and verifies with `nm` that the installed shared
object really is instrumented before running the suite.

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
```

Optional inputs:

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
    with:
      r-version: devel        # default
      timeout-minutes: 60     # default
      env: |                  # extra env for the check step
        MYPKG_SLOW_TESTS=true
```

**Why no ASan here.** ASan instruments a package `.so` fine, but that `.so` is
`dlopen`'d into an R that is not itself instrumented. Making that work needs
`-shared-libasan`, an `LD_PRELOAD` of the runtime into R, and
`detect_leaks=0` — R does not free on exit, so leak detection reports the
interpreter rather than your package. Half-configured it finds nothing; fully
configured it is fragile across R versions. ASan belongs where the C code
links into a real executable: a libFuzzer target or a standalone replay
driver. UBSan has no such problem, because its shared runtime can arrive by
`DT_NEEDED` at `dlopen` time.

For heap errors in an R package, `valgrind.yml` below covers that ground on an
ordinary runner, and the `asan` job below covers it where ASan does work.

#### The `asan` job — AddressSanitizer, in the R-hub containers

Off by default. `asan: true` adds a second job to this workflow that runs the
package under ASan inside `ghcr.io/r-hub/containers/clang-asan` and
`gcc-asan`, verifies with `nm` that the installed shared object really is
instrumented, and fails on a diagnostic in the output as well as on a non-zero
exit.

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
    with:
      asan: true
```

Everything the note above says is true of an ordinary runner. These images
have already done all three things it lists: `clang-asan` ships an R that is
itself a `devel-asan` build, and `gcc-asan` `LD_PRELOAD`s `libasan` from
inside the `R` and `Rscript` wrappers with `ASAN_OPTIONS='detect_leaks=0'` set
image-wide. Their R also compiles packages with
`-fsanitize=address,undefined` from its own `Makeconf`, so this job passes no
sanitizer flags of its own.

Optional inputs:

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
    with:
      asan: true
      asan-containers: '["clang-asan", "gcc-asan"]'   # default
      asan-dependencies: false                        # default true
      asan-run: Rscript tools/sanitizer-exercise.R
```

`asan-run` replaces `R CMD check` with a command of your own. The default path
is fine for most packages — measured at about two minutes on a package with
five Suggests, which pak resolved as binaries from the image's own repository
rather than building them. Reach for `asan-run` when that does not hold: a
Suggests with no binary for the image, a suite too slow to run instrumented,
or a package whose interesting paths are not the ones its tests spend time on.

A sanitizer earns its keep on error and unwind paths — where an R-level
`longjmp` skips whatever C had allocated — and an ordinary suite exercises
those only incidentally. A driver aimed at them needs no dependencies at all,
so pair it with `asan-dependencies: false`.

### `vendor.yml` — vendored-source guard

For packages that bundle third-party sources. Runs the package's own
verifier, and — on pull requests — fails when files under the vendored
directory change without the manifest and checksums changing too.

The PR half is the part a verifier cannot do on its own: reproducibility is
a property of the commit, not of the working tree, so a hand-edited vendored
file whose checksum was re-recorded to match it passes verification happily
and is still unreproducible from the manifest.

```yaml
jobs:
  vendor:
    uses: pedrobtz/r-actions/.github/workflows/vendor.yml@v1
```

Optional inputs:

```yaml
    with:
      vendor-dir: src/vendor                  # default
      verify: tools/vendor/verify             # default; skipped if absent
      must-update: |                          # default
        tools/vendor/manifest.tsv
        tools/vendor/checksums.sha256
```

### `valgrind.yml` — Valgrind

Runs `R CMD check --use-valgrind` under R-release, then **scans the check
output and fails on a finding**. Catches heap errors and memory leaks, and is
the check CRAN runs on their valgrind machine. Slower than the sanitizers job.

```yaml
jobs:
  valgrind:
    uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@v1
    with:
      timeout-minutes: 60     # default
```

The scan is not optional extra credit. `R CMD check` does not fail on a
valgrind finding: valgrind writes to the `.Rout` files, check reads them for R
errors only, and the job goes green with `definitely lost` in a log nobody
opens. Valgrind has no equivalent of UBSan's `halt_on_error`, so grepping the
output is the only way — which is what R-hub's own container scripts do.
The whole check directory is uploaded as an artifact.

### `lto.yml` — Link-Time Optimization

Compiles the package with `-flto` under R-release so the toolchain cross-checks
declarations against definitions across all translation units. Catches function
signature mismatches between C/C++ files that ordinary checks miss. Mirrors
CRAN's "Additional issues: LTO" flavor.

```yaml
jobs:
  lto:
    uses: pedrobtz/r-actions/.github/workflows/lto.yml@v1
```

### `gctorture.yml` — GC Torture

Runs the test suite under R-release with `gctorture2()`, forcing a garbage
collection every `step` allocations (20 by default). Any unprotected `SEXP` that lives
across an allocating call will corrupt memory and surface as a test failure or
crash. Runtime complement to the static `rchk` job.

```yaml
jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1
```

**Raise `step` before you raise the timeout.** Cost scales as roughly
`1/step`, and the measurements are not close — on a package with a
3,000-assertion suite, one test file took 97s at step 20, 11s at 100 and 2.6s
at 500, and its whole suite took 88 to 107 minutes at 20:

```yaml
jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1
    with:
      step: 100
```

What a larger step gives up is sensitivity, not coverage: every path still
runs, and a suite of any size still forces many thousands of collections. An
unprotected `SEXP` is caught when a collection lands while it is live, so a
larger step widens the window it can hide in. Prefer 100 over not running this
job at all.

Most of that cost is not your package. `expect_*()` allocates heavily —
comparison, condition objects, srcrefs — so on the measurement above, 40 raw
parse-and-emit cycles cost 2.6s at step 20 while 44 assertions cost 97s. Which
is also why gating a few slow tests moves the total far less than `step` does.

The job times out after 120 minutes by default; raise it with the
`timeout-minutes` input:

```yaml
jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1
    with:
      timeout-minutes: 240
```

Prefer gating the heavy tests instead, where you can. `testthat::test_local()`
sets `NOT_CRAN`, so anything behind `skip_on_cran()` *will* run here — and
tests that check limits (row counts, column caps, file sizes) rather than
memory safety cost this job a great deal and tell it nothing.

### `rchk.yml` — rchk static analysis

Runs [Tomas Kalibera's rchk](https://github.com/kalibera/rchk) static analyzer
inside Docker against the package's source tarball. Proves PROTECT-stack
correctness (unprotected SEXPs, imbalanced PROTECT/UNPROTECT) that neither
`R CMD check` nor the sanitizers detect. The job is informational: findings are
uploaded as an artifact rather than hard-failing the build, because rchk can
report false positives that need human judgement.

```yaml
jobs:
  rchk:
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@v1
```

Once a package is at zero findings the calculation reverses — the next one is
a regression, and a warning nobody opens is not how you want to hear about it:

```yaml
jobs:
  rchk:
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@v1
    with:
      fail-on-findings: true
```

## Usage

### R CMD check

Copy [`examples/r-cmd-check.yml`](examples/r-cmd-check.yml) into your package
as `.github/workflows/R-CMD-check.yml`, replacing the r-lib/actions template:

```yaml
on:
  push:
    branches: [main, master]
  pull_request:

name: R-CMD-check

permissions: read-all

jobs:
  R-CMD-check:
    uses: pedrobtz/r-actions/.github/workflows/r-cmd-check.yml@v1
```

Keep the file name your badge already points at — the workflow's own `name:`
is what the UI shows, and the caller's file name is what the badge URL uses.

### Coverage

Copy [`examples/coverage.yml`](examples/coverage.yml) into your package as
`.github/workflows/coverage.yml`. The `paths-ignore` filter prevents a push
loop when the workflow commits an updated badge:

```yaml
on:
  push:
    branches: [main, master]
    paths-ignore:
      - ".github/badges/coverage.svg"
  pull_request:

name: coverage

jobs:
  coverage:
    uses: pedrobtz/r-actions/.github/workflows/coverage.yml@v1
    permissions:
      contents: write
```

### Run all native checks together

Copy [`examples/native-checks.yml`](examples/native-checks.yml) into your
package as `.github/workflows/native-checks.yml`:

```yaml
on:
  push:
    branches: [main, master]
  pull_request:

name: native-checks

jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1

  valgrind:
    uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@v1

  lto:
    uses: pedrobtz/r-actions/.github/workflows/lto.yml@v1

  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1

  rchk:
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@v1
```

All five jobs appear under a single workflow run in the GitHub UI and execute
in parallel.

### Run a subset

Drop any jobs you don't need. For example, a package with no C/C++ code only
needs `gctorture`:

```yaml
on:
  push:
    branches: [main, master]
  pull_request:

name: native-checks

jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1
```
