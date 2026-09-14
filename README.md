# r-actions

Reusable GitHub Actions workflows for R packages, covering test coverage,
memory safety, undefined behaviour, and static analysis checks that complement
the standard `R CMD check` run by [r-lib/actions](https://github.com/r-lib/actions).

## Versioning

Workflows are released under [semantic versioning](https://semver.org/). Pin
consumers to a major-version tag (e.g. `@v1`) to receive backwards-compatible
updates automatically, or to an exact tag (e.g. `@v1.0.0`) to lock a specific
release. Avoid `@main`—it tracks the development tip and may contain breaking
changes.

See [Releases](https://github.com/pedrobtz/r-actions/releases) for the full
changelog.

## Workflows

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

`asan-run` replaces `R CMD check` with a command of your own, and is worth
reaching for. `R CMD check` in these images builds every Suggests dependency
from source under the sanitizer, which is slow and occasionally fails for
reasons unrelated to your package. A small driver that exercises the compiled
code with base R only — error paths especially, where an R-level `longjmp`
skips whatever C had allocated — runs in a minute and is what the sanitizer
actually cares about. Pair it with `asan-dependencies: false` when the driver
needs nothing but base R.

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

Runs the test suite under R-release with `gctorture2(step = 20)`, which forces
a garbage collection every 20 allocations. Any unprotected `SEXP` that lives
across an allocating call will corrupt memory and surface as a test failure or
crash. Runtime complement to the static `rchk` job.

```yaml
jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@v1
```

The job times out after 120 minutes by default. Because a GC every 20
allocations makes everything slow, a package with large test data can exceed
that; raise the limit with the `timeout-minutes` input:

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
