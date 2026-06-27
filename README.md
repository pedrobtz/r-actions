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

### `sanitizers.yml` — AddressSanitizer + UndefinedBehaviorSanitizer

Builds and checks the package under R-devel with clang, ASAN, and UBSAN enabled.
Detects memory errors (heap overflows, use-after-free, memory leaks) and
undefined behaviour (signed integer overflow, misaligned pointers, etc.).
Mirrors CRAN's "Additional issues: ASAN/UBSAN" flavor.

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
```

### `valgrind.yml` — Valgrind

Runs `R CMD check --use-valgrind` under R-release. Catches heap errors and
memory leaks that ASAN may miss, and is the check CRAN runs on their valgrind
machine. Slower than the sanitizers job.

```yaml
jobs:
  valgrind:
    uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@v1
```

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
