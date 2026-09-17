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
| `containers` | `clang23`, `ubuntu-clang`, `ubuntu-gcc16` | `r-devel-linux-x86_64-debian-clang`, `r-devel-linux-x86_64-debian-gcc` |

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

**The containers are overridden to compile the way CRAN does**, because out
of the box they do not. Measured on the images themselves:

| | `CC` | `CFLAGS` | C++ stdlib |
|---|---|---|---|
| CRAN debian-clang | `clang-23 -std=gnu23` | `-g -O3 -Wall -pedantic` | libstdc++ |
| `clang23` | `clang-23` | `-O3 -Wall -pedantic` | **libc++** |
| `ubuntu-clang` | **`clang-22`** | **`-g -O2`** | libstdc++ |
| `ubuntu-gcc16` | `gcc-16 -std=gnu2x` | `-g -O2` | — |

No single image is CRAN's debian-clang. `clang23` has the right compiler
major and CRAN's exact C flags but builds C++ against libc++; `ubuntu-clang`
has the right C++ standard library and is the image r-hub badges as that
flavor, but is pinned to clang 22 and ships no `-pedantic`. The default runs
both, because they fail differently.

`-pedantic` matters more than it looks: it, not `-Wall`, is what enables
several of the diagnostics only CRAN reports. Unoverridden, `ubuntu-clang`
gave a package a clean bill of health on sources CRAN had already rejected
with four `-Wkeyword-macro` warnings. And clang 23 itself still defaults to
`__STDC_VERSION__ 201710L` — CRAN's `-std=gnu23` is an explicit choice, so
forcing it is necessary rather than redundant.

`container-makevars` closes it, appending to a user Makevars that R reads
after its own `Makeconf`:

```make
CC     += -std=gnu23
CFLAGS += -pedantic
```

`+=` rather than `=`, so the image keeps its own compiler and only gains the
flags — that survives the image bumping clang versions. Set it to `""` to
take the images exactly as they ship.

The lines are **appended to whatever user Makevars the image already uses**,
never written somewhere new and pointed at with `R_MAKEVARS_USER`. That
variable *replaces* the user Makevars rather than adding to it, and `clang23`
configures its entire toolchain there — `COPY Makevars /root/.R` plus
`ENV R_MAKEVARS_USER=/root/.R/Makevars`, with no `Makeconf` patching at all.
Repointing it threw that away and fell back to `Makeconf`'s gcc, so a
container named `clang23` checked with GCC and passed.

Every container run logs the image's `CC`, `CXX`, flags and resulting
`__STDC_VERSION__` before checking, so "is this image really the flavor I
think it is?" is answerable from the log rather than from a debugging round
trip. That step is how the mismatch above was found.

Optional inputs:

```yaml
    with:
      containers: '["clang23", "ubuntu-clang", "ubuntu-gcc16"]'  # default; '[]' skips
      container-makevars: |                            # default; "" takes images as-is
        CC += -std=gnu23
        CFLAGS += -pedantic
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
yellow ≥ 75 %, orange ≥ 60 %, red below 60 %. The badge is rendered from a
template in the workflow itself, so the job that can write to your repository
downloads nothing to do it.

It runs as two jobs. `coverage` runs covr — and so the package's tests, and
its dependencies — with a read-only token. `badge` holds the write token, runs
only on `push`, and does nothing but render the SVG and commit it.

> **Note:** this workflow commits back to the repository, so the caller must
> grant `contents: write`. That grant is the ceiling for the whole workflow;
> only the `badge` job requests it.

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

#### `native: true` — coverage of the C, separately

covr measures R code. For a package that is mostly a C parser behind a thin R
wrapper, that number can look excellent while large parts of the C are never
executed by any test — and a `.covrignore` excluding the vendored sources,
which is the right call for a badge, leaves the question unanswered rather
than answering it.

```yaml
jobs:
  coverage:
    uses: pedrobtz/r-actions/.github/workflows/coverage.yml@v1
    permissions:
      contents: write
    with:
      native: true
```

A separate job builds with `--coverage`, runs the suite, and writes a per-file
gcov table to the job summary:

| File | Lines | Line cov | Branches | Taken at least once |
|:-----|------:|---------:|---------:|--------------------:|
| `src/parser.c` | 13 | 100.00% | 12 | 58.33% |

**Read the last column.** That row is real output from a small parser whose
tests only ever pass it valid input: every line runs, and well under half the
branches are ever taken. A parser's error handling is overwhelmingly
`if (err) goto fail;` — the line executes on the happy path, the branch does
not, and those paths are exactly where the interesting bugs are. gcov's
"Branches executed" counts a branch as covered when the instruction ran at
all, so the honest number is "taken at least once".

It is **not a badge and not a gate**, deliberately. A low figure on a vendored
file may be entirely correct: a bundled library carries modules the package
never calls and cannot drop from the tarball. This number wants reading, not
defending.

`native-run` replaces the default (running each file in `tests/` the way
`R CMD check` does) when coverage should reflect something else — a
conformance corpus, a replay driver. `native-exclude` drops paths from the
table, matched as in `vendor.yml`; it is empty by default on purpose, since
how much of the vendored parser your tests actually reach is the question
worth asking. Note that `.covrignore` does not apply here — that is covr's,
and this job does not use covr.

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

#### Checking beyond CRAN's UBSan subset

The default flags are UBSan as CRAN configures it, which is the point: the
flavor that can reject a submission is the one worth matching. CRAN's set is a
subset of what UBSan offers, though, and the omitted checks are aimed at the
arithmetic a parser does constantly.

`extra-ubsan-checks` appends to the flags, in this job and in the `asan`
containers. `ubsan-suppressions` is a file of the cases you have looked at and
accepted.

```yaml
jobs:
  sanitizers:
    uses: pedrobtz/r-actions/.github/workflows/sanitizers.yml@v1
    with:
      extra-ubsan-checks: -fsanitize=integer
      ubsan-suppressions: tools/ubsan.supp
```

| flag | catches |
|:--|:--|
| `-fsanitize=integer` | unsigned overflow and truncation |
| `-fsanitize=implicit-conversion` | narrowing that silently loses data |
| `-fsanitize=local-bounds` | bounds on local arrays |

`integer` is the one with the best ratio. Unsigned overflow is *defined*
behaviour, so CRAN has no reason to check it, and it is still a bug when it
happens to a size, an offset or a depth counter — a package whose safety rests
on bounded counters is making a claim about exactly this arithmetic.

None of these can be on by default, because they fire on correct and
deliberate code: hash mixing wants wrapping, and a checked narrowing is still
a narrowing. Write the deliberate cases down instead, one `<check>:<file or
function>` per line:

```
unsigned-integer-overflow:src/hash.c
implicit-signed-integer-truncation:pack_header
```

Two things worth knowing before you turn these on. They are **fatal**, like
the default set, but by a different route — `-fno-sanitize-recover=undefined`
does not cover these groups, and `halt_on_error=1` stops the process on one
anyway. So the run ends at the first finding, and adoption means working
through them a run at a time. And these are clang spellings: GCC has no such
groups, so `gcc-asan` skips them rather than failing to build, and says so in
the log.

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

**When the vendored files are not a directory of their own**, use `paths`
instead. It takes one entry per line, overriding `vendor-dir`: an entry with
no glob character is a directory prefix, anything else is matched as a shell
glob against each changed path.

```yaml
    with:
      paths: |
        src/cyaml*.c
        src/cyaml*.h
```

This is not a corner case. A package that bundles a C library and compiles it
with its own sources has both in `src/`, deliberately — `R CMD SHLIB` builds
one flat directory, and moving the bundled code into a subdirectory costs an
`OBJECTS` list and a GNU-make dependency. A directory prefix cannot say "the
bundled files and not mine", so the guard would either watch nothing or fire
on every commit, and a guard that fires on everything is one people learn to
ignore.

### `vendor-upstream.yml` — is the vendored library stale?

`vendor.yml` above guards against **drift** — someone editing the bundled
library by hand. It says nothing about **staleness**: the vendored copy being
an old version of something upstream has since fixed. A package can sit on a
pinned version indefinitely, every check green, while upstream ships a bounds
fix for the parser it bundles.

This is the gap Dependabot fills for npm and PyPI. Vendored C has none of that
machinery — no manifest a scanner recognises, no registry to query — so
vendoring trades a system dependency for the job of watching upstream
yourself, and this automates that half.

Run it on a schedule. It reads your pinned version, asks upstream what the
latest is, and opens an issue when they differ — editing that same issue on
later runs rather than opening a new one each week.

```yaml
on:
  schedule:
    - cron: "0 6 * * 1"
  workflow_dispatch:

jobs:
  upstream:
    uses: pedrobtz/r-actions/.github/workflows/vendor-upstream.yml@v1
    permissions:
      contents: read
      issues: write
    with:
      upstream-repo: tlsa/libcyaml
      current-version: sed -n 's/^CYAML_VERSION=//p' tools/vendor-cyaml.sh
```

`current-version` is a command rather than a path, because every package
records this differently and none should have to move it to adopt this — a
vendoring script holds it in a variable, a header as a `#define`, a manifest
in a column. A leading `v` is stripped from both sides.

It **never fails the check**. A new upstream release is information, not a
defect, and a red X on unrelated PRs is the kind of signal people route around
— including, eventually, the vendor guard sitting next to it. Set
`on-new-version: summary` to skip the issue and only write the job summary,
`include-prereleases: true` to count prereleases, and `labels:` to tag the
issue (left empty by default, because a label that does not exist in your
repository makes the API call fail).

It also reports any **published security advisories** on the upstream
repository. That is best-effort: it is keyed on the repository rather than on
a package name in an ecosystem a vendored C library does not belong to, and a
project that publishes advisories elsewhere will show none here.

> **Note:** this workflow opens issues, so the caller must grant
> `issues: write`.

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

#### A baseline, so the gate survives its first false positive

`fail-on-findings` alone is a boolean, and a boolean has one bad day in it.
The first time rchk reports a false positive against a package that has
already turned the gate on, the choices are to leave CI red on something that
is not a bug, or to set `fail-on-findings: false` and lose the gate entirely —
including for the real regression next month. The second is what actually
happens, because a red check everyone knows is wrong gets routed around within
a day.

`baseline` is a checked-in file of accepted findings. The job then fails only
on findings that are *not* in it — the same shape, and the same reason, as
`valgrind.yml`'s `suppressions`.

```yaml
jobs:
  rchk:
    uses: pedrobtz/r-actions/.github/workflows/rchk.yml@v1
    with:
      fail-on-findings: true
      baseline: tools/rchk.baseline
```

One finding per line, three tab-separated fields — tag, function, file — with
`#` comments ignored:

```
# upstream false positive: v is protected by the caller
UP	cyaml_parse_document	src/zuyaml_parse.c
```

You do not have to write these by hand. When the job finds something unlisted
it prints the exact lines to add.

The key is deliberately **not** the line number, the message, or the path rchk
actually prints. Line numbers move with any edit above them, and rchk builds
the package in a directory with a random name — its own README shows
`/rchk/trunk/packages/build/IsnsJjDm/jpeg/src/read.c` — so a baseline keyed on
what rchk prints would match nothing on the next run and look exactly like a
package that had fixed everything. Paths are cut back to `src/…` first. The
cost is that two findings of the same tag in one function collapse to one
entry; that is the trade, and it is the right way round.

A baseline entry that **stops reproducing** is also an error. Without that the
file only ever grows: entries accumulate, nobody removes them, and eventually
one suppresses a real finding it happens to match. Making a disappeared entry
fail means fixing the code forces you to delete its line, so the file shrinks
over time instead.
### `analyzers.yml` — static analysis, starting with `-fanalyzer`

The other two static checks here are narrow on purpose: `rchk.yml` reasons
about R's PROTECT discipline, `lto.yml` catches declarations drifting between
translation units. Neither looks at allocator lifecycle, which is the bug
class a vendored C parser actually carries — leak on an error path, free of a
partially built node, use after the stream is torn down.

GCC's `-fanalyzer` is a symbolic-execution pass covering exactly those:
`-Wanalyzer-double-free`, `-Wanalyzer-use-after-free`,
`-Wanalyzer-malloc-leak`, `-Wanalyzer-null-dereference`,
`-Wanalyzer-file-leak`. Unlike ASan and valgrind, which only see paths
something actually ran, it reaches code no test executes.

```yaml
jobs:
  analyzers:
    uses: pedrobtz/r-actions/.github/workflows/analyzers.yml@v1
```

It builds in an R-hub GCC container, writes a per-check table to the job
summary, uploads the build log, and — by default — does not fail the build.
That is the same trajectory `rchk.yml` takes, for the same reason: the known
cost of `-fanalyzer` is false positives on unusual control flow, and a package
meeting it for the first time should not be blocked while it works through
them. Turn the gate on once it is at zero.

```yaml
jobs:
  analyzers:
    uses: pedrobtz/r-actions/.github/workflows/analyzers.yml@v1
    with:
      fail-on-findings: true
      exclude: |
        src/cyaml*.c
      container: ubuntu-gcc16      # default
      analyzer-flags: -fanalyzer   # default
      timeout-minutes: 45          # default
```

`exclude` is for vendored third-party sources: you are not going to fix
upstream's findings, and a report full of them is one people learn to skip.
Patterns match the same way `vendor.yml`'s do — an entry with no glob
character is a directory prefix, anything else is a glob — and are written
repo-relative (`src/cyaml*.c`) even though R compiles from inside `src/` and
the compiler says `cyaml.c`; the job puts the path back before matching.
Excluded findings are still shown in the summary, under their own heading,
rather than dropped.

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

### Watching a vendored library

Copy [`examples/vendor-upstream.yml`](examples/vendor-upstream.yml) into your
package as `.github/workflows/vendor-upstream.yml` and point it at the
upstream repository.

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
