# r-actions v2: CI as a shared budget

**Status:** proposal, 2026-11-11. Nothing here is built yet. v1 stays as it
is until v2 is released; callers move by changing `@v1` to `@v2`.

## 1. Why

v1 was designed one package at a time. Each workflow answers "what should
this package check?", and the answer is "as much as possible, on every
change". That was right for one package. With forty packages on one account,
it is wrong. The runners are a single pool that every package draws from,
and v1 has no notion of that pool.

### 1.1 What we have

| Resource | Free plan (today) | Pro |
|---|---|---|
| Jobs running at once, whole account | 20 | 40 |
| macOS jobs at once | 5 | 5 |
| Minutes on public repositories | unmetered | unmetered |
| Artifact storage | 0.5 GB | 1 GB |
| Merge queue (`merge_group`) | no: needs an organisation | no |

Check these against GitHub's current limits page before relying on them. The
20 is not a guess: on 2026-11-11 the account sat at exactly 20 running jobs
for hours, with 484 queued.

The portfolio has 40 non-archived repositories. Each one carries 4 to 15
workflow files.

### 1.2 What it costs today (measured)

- **One code push to a zuhttp pull request on the quick profile is 53 jobs
  and about 510 runner-minutes**: 49 Ubuntu, 2 macOS, 2 Windows (#335,
  2026-11-11). With 20 slots, that one push fills the account for about 25
  minutes. Three packages pushing at once fill it for over an hour.
- **Pushes to main are more than half the load.** Of 206 open runs on
  2026-11-11, 111 were `push`, 68 `pull_request`, and 26 GitHub Pages
  deployments. The push after a merge re-checks a tree the pull request
  already checked: a pull request runs on the merge of its head with its base.
- **One housekeeping sweep produced 272 queued jobs.** The CLAUDE.md
  adoption pull requests, prose plus a few `.Rbuildignore` lines in 28
  packages, ran their pull request checks, were cancelled, and then ran
  everything again on each merge to main. `.Rbuildignore` counts as code to
  the `changes` gate, which is correct, and the push carries no label.
- **Deciding to skip costs a runner.** Before v1.38, a README-only pull
  request took 12 runners just for the `changes` gates to decide that nothing
  should run. v1.38's label gates fix this, but only for pull requests that
  carry a label.
- **macOS is the hard limit.** Eight one-minute macOS jobs per pull request
  queued four pull requests behind each other in zuhttp. Some were then
  cancelled with "The job was not acquired by Runner of type hosted". Six
  pull requests from one zuhttp review pass queued for hours.
- **The weekly runs start together.** The callers copy the examples'
  schedules, so most full runs start on Monday between 03:00 and 07:00 UTC
  (`41 4 * * 1`, `0 7 * * 1`, `47 4 * * 1` in eight packages sampled). The
  slowest jobs in the full set, gctorture at step 20 (36 to 107 minutes) and
  valgrind, all land in the same few hours.

### 1.3 What the checks find

This decides what has to run before a merge and what can wait.

- **The 16 bugs of the 2026-11-09 zuhttp reviews passed every CI check.**
  Code-reading reviews and a scripted bug hunt found them. No workflow did,
  because CI proves "it does not crash", not "it is right"
  (`correctness.md`).
- **The CRAN-like containers find what CRAN's pretest would reject.** A
  clang-23 `-pedantic` warning only shows there. That makes `clang23` the one
  container worth running before a merge.
- **gctorture, valgrind, ASan, rchk, the macOS and Windows legs and the
  R-devel legs find rare, slow-to-appear faults.** v1 already defers most of
  them to the full profile, and the portfolio accepted that a full-only
  failure is found at the next weekly run. Nothing in 2026-10 or 2026-11 made
  a case for running them on every push.
- **Flakes cost re-runs, and each re-run costs runners again**: the Azure
  apt mirror's DNS, pak's index download.

### 1.4 What is wrong with v1's model

1. **Everything runs unless something says otherwise.** A pull request with
   no label gets the whole quick set. Agents and people forget labels, and
   the default is the most expensive outcome.
2. **A push to main is treated as a check event.** It re-runs the quick set
   for every merge, in every package, with no label to stop it.
3. **The gate is per workflow.** Each workflow runs its own `changes` job, so
   the number of runners spent deciding grows with the number of workflow
   files.
4. **Nobody sees the budget.** No workflow knows the account is at 20/20,
   and no report says which package used which share.
5. **Callers are copied, not generated.** Forty repositories each hold their
   own copies of the examples. A change to the policy means hand edits in 40
   repositories, and they drift; zuhttp alone has 15 workflow files.

## 2. Principles

1. **The account is the unit.** Every default is judged by its cost across
   40 packages, not one.
2. **Nothing expensive runs by default.** A check beyond the smoke tier runs
   because a label, a schedule or a dispatch asked for it.
3. **Decide without a runner.** Every run/skip decision that can be made
   from the event is made in a job-level `if:`, which GitHub evaluates
   without a runner. Reading the file list costs a runner, so it is used only
   to skip further, never to decide that something runs.
4. **Check once before a merge, not on every push to main.** The pull
   request's run is the pre-merge check. Main gets the site, and a scheduled
   full run.
5. **The full set runs on a timetable**: staggered across packages, and
   skipped when main has not changed since its last green full run.
6. **The policy is generated, not copied.** One source in
   `pedrobtz/packages` writes every package's callers, the way
   `.claude/shared` is synced today.

## 3. The design

### 3.1 Tiers

Every check belongs to exactly one tier.

| Tier | What runs | Jobs | When |
|---|---|---|---|
| `smoke` | R CMD check on Ubuntu R-release, the `clang23` container, UBSan (gcc) when the package has `src/` | 2 or 3 | every pull request push, unless it is `ci:docs` |
| `native` | ASan, valgrind, rchk, lto, analyzers, gctorture at the quick step, cran-special | 6 to 10 | label `ci:native` |
| `platforms` | macOS and Windows R CMD check, and the package's `platforms.yml` | 2 to 4 | label `ci:platforms` |
| `fuzz` | corpus replay, and a short libFuzzer run | 1 or 2 | label `ci:fuzz` |
| `full` | everything: every tier, all containers, oldrel, `nosuggests`, `nold`, R-devel on Windows, gctorture at step 20 | the whole set | weekly schedule, dispatch, label `full-ci` |

`smoke` is the default for pull requests. It is the safety net; see 3.3 for
why it exists. A code pull request with no label costs 2 or 3 jobs instead
of 53.

A tier label adds to `smoke`. It never replaces it. `full-ci` implies every
tier. A package's own workflow declares its tier in the generated caller
(3.6), the same way.

### 3.2 Labels

| Label | Effect |
|---|---|
| (none) | `smoke` |
| `ci:docs` | nothing gated runs; pkgdown builds the preview if the package has one |
| `ci:native`, `ci:platforms`, `ci:fuzz` | `smoke` plus that tier; any combination |
| `full-ci` | the full set |
| `skip-ci:<workflow>` | that workflow off, whatever else says it should run |

`ci:minimal` goes. It is today's `smoke`, so it becomes the default.

Every label is tested in the calling job's `if:`, so a pull request with
`ci:docs` starts no runner at all. Agents choose the label from the diff,
using the table in `ci.md`, which the skills already follow:

| The pull request changes | Labels |
|---|---|
| only prose, or `.claude/`, `.agents/` | `ci:docs` |
| R code only | none |
| C, C++ or Rust code | `ci:native` |
| code that is platform-specific (`#ifdef _WIN32`, a TLS backend, `configure.win`) | `ci:native`, `ci:platforms` |
| a parser or decoder with a fuzz harness | add `ci:fuzz` |
| a vendored library, a `PROTECT` or finaliser change, the last pull request of a milestone, a release | `full-ci` |

### 3.3 Why `smoke` is not zero

With opt-in labels taken literally, a pull request without a label would run
nothing. That is cheaper, but on this account it is unsafe. Branch
protection cannot catch the forgotten label: a job skipped by its `if:`
reports *skipped*, and GitHub counts *skipped* as passing for a required
check. An unlabelled code change would then merge with a green but empty
check list, and nothing would notice until the weekly run.

`smoke` costs 2 or 3 jobs and closes that hole. It runs the package's tests
and install once, on the compiler CRAN's pretest uses. `ci:docs` remains the
explicit way to run nothing.

If GitHub ever exposes a "check did not run" status that branch protection
can require, `smoke` can become opt-in too. Until then it stays.

### 3.4 Push to main

A push to main runs:

- **pkgdown**, to deploy the site, gated on files a site reads (`R/`, `man/`,
  `vignettes/`, `README.*`, `NEWS.md`, `_pkgdown.yml`, `pkgdown/`). This is
  the one push job that needs the file list, and it only ever skips.
- **Nothing else.** Coverage moves to the weekly run, and its badge updates
  weekly. R CMD check and the native checks are not re-run.

What this gives up: when two pull requests are merged one after the other,
each was checked against main *before* the other landed. A conflict between
them in meaning, not in text, is found at the next scheduled run, not at the
merge. With no merge queue on a personal account, that is the trade. 3.5
shortens the wait.

`[skip ci]` in a pull request title ends up in the merge commit, so a
portfolio-wide housekeeping sweep (a sync, a CLAUDE.md move) can skip even
pkgdown. The sync script already puts it in its commits (packages #190).

### 3.5 Scheduled runs

- **Daily `smoke` on main, only if main moved.** A scheduled job reads the
  last green `smoke` run's commit through the API, in a job that takes
  seconds. If main has not moved since, it stops. If it has, it runs `smoke`
  once, however many merges landed. This replaces the per-merge push check
  with at most one per package per day, and finds the two-merge conflict of
  3.4 within a day.
- **Weekly `full`, only if main moved since the last green `full`.** Most
  packages are dormant in any given week. A dormant package skips its full
  run. A package that has not run `full` for four weeks runs it anyway,
  because the containers and R-devel change under it.
- **Staggered.** The generator (3.6) gives each package its own slot. Each
  package gets an hour and a weekday from a hash of its name, spread over
  Saturday 00:00 to Monday 06:00 UTC. That is about 54 hours, so the 40
  packages are about 80 minutes apart. A full run that takes 60 to 110
  minutes then overlaps with at most one or two others.

### 3.6 One caller per package, generated

Each package gets two workflow files, written by a generator in
`pedrobtz/packages` and synced as `.claude/shared` is:

- `ci.yml`: every event (pull request, push, schedule, dispatch). Its jobs
  call the r-actions workflows, each with the label-and-tier `if:` of 3.2.
  There are no `changes` jobs on pull requests: the labels decide, and the
  file list is no longer needed there.
- `ci-own.yml`, optional: the package's own checks, each declaring its tier
  in a comment the generator reads, for example `# tier: native`. The
  generator writes the `if:`.

The generator reads a short per-package file, `.github/ci.toml`:

```toml
compiled = true          # adds UBSan to smoke, enables the native tier
fuzz = true
platforms = true         # the package has tools/ci/platform.sh
containers = ["clang23"] # smoke's container
full-containers = ["clang23", "ubuntu-clang", "ubuntu-gcc16"]
```

Moving 40 packages to v2 then means one generator change and one sync, not
40 hand edits. The `assurance.yml` gating step checks that the callers match
the generator's output, so a hand edit is reported.

### 3.7 Budget visibility

- **`report.yml` gains a budget section.** Weekly, for each package: the
  runner-minutes it used, split by event and tier, and its longest queue
  wait. Written to an issue in `pedrobtz/packages`. This is the number that
  says whether Pro (40 slots) would help, and who would use the extra slots.
- **A queue check in the generated `ci.yml`.** Before the `full` tier on a
  dispatch, a job of a few seconds reads the account's queued-job count. Over
  a threshold (default 100), it waits up to 30 minutes for the queue to fall,
  then runs regardless.

### 3.8 Flakes

A retry costs a whole job. The known flakes are all downloads: the Azure apt
mirror, pak's index, the r-hub images. r-actions retries those steps inside
the job, three times with backoff, so a flake costs seconds rather than a
re-run. A step that fails for any other reason is not retried.

## 4. What it saves (estimated from 1.2)

| Event | v1 quick | v2 |
|---|---|---|
| Code push to a pull request, zuhttp | 53 jobs | 3 (`smoke`), about 12 with `ci:native` |
| Docs pull request with its label | 0 | 0 |
| Docs pull request without a label | 12 gate runners | 3 (`smoke`) |
| Merge to main | about 53 | 0 or 1 (pkgdown) |
| Housekeeping sweep, 28 packages | 272 queued jobs, after cancellations | 0 with `[skip ci]` and `ci:docs` |
| Weekly full, 40 packages | 40 full sets, mostly Monday 03:00 to 07:00 UTC | only packages that changed, about 80 minutes apart |

These are estimates from the measurements in 1.2, not measurements of v2.
The `report.yml` budget section (3.7) is how v2 gets measured once it runs.

## 5. Alternatives considered

- **GitHub Pro, $4 a month.** It doubles Ubuntu concurrency to 40. It does
  not raise macOS, which stays at 5, and it does not change the model. A
  sweep like 1.2's would still fill 40 slots, just for half as long. Pro is
  worth it alongside v2 if the budget report shows real queue waits, not
  instead of v2.
- **An organisation (Team plan).** It would give merge queues, which would
  restore checking on main without a second run, and 60 slots. But it means
  moving 40 repositories, every r-actions reference and every badge.
  Revisit at 1.0 of the portfolio's core packages, not now.
- **Self-hosted runners.** They do not count against the 20 slots. On public
  repositories, though, a pull request from a fork runs its own code on the
  machine. They would be acceptable only for `schedule` and
  `workflow_dispatch` events, for example gctorture and valgrind at full
  depth on a home machine. That is an option to keep for later, not part of
  v2.
- **Opt-in with nothing by default.** Rejected for the reason in 3.3: a
  skipped job passes a required check.
- **Keep per-workflow `changes` gates, add more labels.** That is v1.38, and
  it still leaves the push to main and the unlabelled pull request at full
  cost.

## 6. Migration

1. **r-actions v2.0.0.** Tier inputs replace `profile`. Each workflow takes
   `tier` and the label set; the label tests move into the generated callers.
   Download retries go in (3.8). v1 stays on its tag and is not changed
   further except for fixes.
2. **The generator in `pedrobtz/packages`** (`tools/ci-callers/`),
   `.github/ci.toml` for each package, and the sync job, opening its pull
   requests with `ci:docs` and `[skip ci]`.
3. **`ci.md` and the skills.** The tier and label tables, `ci:minimal`
   retired, "push to main runs the site only". `pkg-implement`'s label table
   follows `ci.md`.
4. **Pilot on three packages:** zuhttp (compiled, own workflows, fuzz),
   zujson (small), zuarrow (busy). Two weeks, with the budget report on.
5. **Then the rest**, one sync pull request each, merged on `ci:docs`.
6. **Assurance.** `assurance.yml`'s Required checks rows (`sanitizers`,
   `valgrind`, `rchk`, `gctorture`, `fuzz` …) are `done` when the scheduled
   `full` tier runs them, which it does. Rows stay `done`; the only change is
   when they run.

## 7. Open questions

1. Should `smoke` include the `clang23` container? It is the most CRAN-like
   check, but it installs Suggests from source on R-devel, which takes minutes
   for some packages. The alternative is to keep it out of `smoke` and run it
   daily (3.5).
2. Should coverage stay on pull requests for packages whose `assurance.md`
   sets a coverage floor? The floor is checked weekly if it moves to `full`.
3. The daily `smoke` on main: is a day an acceptable delay for the two-merge
   conflict, or should it run on every merge when the package had two merges
   within an hour?
4. The stagger window: Saturday 00:00 to Monday 06:00 UTC assumes the
   maintainer works weekdays. Is that right?
