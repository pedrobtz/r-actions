# r-actions

Reusable GitHub Actions workflows for R packages, covering memory safety,
undefined behaviour, and static analysis checks that complement the standard
`R CMD check` run by [r-lib/actions](https://github.com/r-lib/actions).

## Workflows

### `sanitizers.yml` — AddressSanitizer + UndefinedBehaviorSanitizer

Builds and checks the package under R-devel with clang, ASAN, and UBSAN enabled.
Detects memory errors (heap overflows, use-after-free, memory leaks) and
undefined behaviour (signed integer overflow, misaligned pointers, etc.).
Mirrors CRAN's "Additional issues: ASAN/UBSAN" flavor.

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@main
```

### `valgrind.yml` — Valgrind

Runs `R CMD check --use-valgrind` under R-release. Catches heap errors and
memory leaks that ASAN may miss, and is the check CRAN runs on their valgrind
machine. Slower than the sanitizers job.

```yaml
jobs:
  valgrind:
    uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@main
```

### `lto.yml` — Link-Time Optimization

Compiles the package with `-flto` under R-release so the toolchain cross-checks
declarations against definitions across all translation units. Catches function
signature mismatches between C/C++ files that ordinary checks miss. Mirrors
CRAN's "Additional issues: LTO" flavor.

```yaml
jobs:
  lto:
    uses: pedrobtz/r-actions/.github/workflows/lto.yml@main
```

### `gctorture.yml` — GC Torture

Runs the test suite under R-release with `gctorture2(step = 20)`, which forces
a garbage collection every 20 allocations. Any unprotected `SEXP` that lives
across an allocating call will corrupt memory and surface as a test failure or
crash. Runtime complement to the static `rchk` job.

```yaml
jobs:
  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@main
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
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@main
```

## Usage

### Run all checks together

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
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@main

  valgrind:
    uses: pedrobtz/r-actions/.github/workflows/valgrind.yml@main

  lto:
    uses: pedrobtz/r-actions/.github/workflows/lto.yml@main

  gctorture:
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@main

  rchk:
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@main
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
    uses: pedrobtz/r-actions/.github/workflows/gctorture.yml@main
```
