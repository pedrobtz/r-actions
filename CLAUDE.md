# CLAUDE.md

<!-- markdownlint-disable-next-line MD013 -->
This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Reusable GitHub Actions workflows (`on: workflow_call`) for the R packages
of the pedrobtz portfolio, and for anyone else. Packages call them from thin
callers; `examples/` holds the caller to copy for each. There is no code to
build: the product is the YAML in `.github/workflows/`, the shell and Python
inside it, and the README that documents every input.

The README is the reference for what each workflow does and why. Read the
workflow's section there before changing it; its claims are the contract
callers rely on. `.agents/v2-design.md` is the accepted plan for v2 (CI as a
shared budget); v1 stays as it is until v2 is released.

## Layout

- `.github/workflows/*.yml`: the reusable workflows. `self-test.yml` and
  `release.yml` are this repository's own.
- `examples/`: one caller per workflow, the shape packages copy.
- `tests/`: shell and Python checks that extract the scripts inside the
  workflows and run them on fixtures (`tests/fixtures/`). `self-test.yml`
  runs each as a job.
- `README.md`: the documentation, one section per workflow.

## Working rules

- **The callers are the users.** 70-odd packages pin `@v1`, so a merge to
  main reaches all of them at the next release. Keep every change backwards
  compatible within v1: a new input gets a default that keeps the old
  behaviour, an output keeps its meaning, a step keeps its `id` if a test or
  caller reads it.
- **Comments say why, with the evidence.** The workflows record what was
  measured and which package hit what ("measured: ...", "found by ..."). Keep
  that standard: a non-obvious step carries the reason, and a reason that was
  measured says so.
- **Everything a caller passes reaches a script through `env:`**, never
  interpolated into `run:` with `${{ }}`. A finding, a file name or an input
  can be text someone else chose.
- **No `${{ }}` in an input's `description`.** None of the workflows has one;
  write the expression in prose and show it in `examples/`.
- **Permissions are least privilege and declared.** `tests/lint-workflows.py`
  holds the list of workflows allowed to write (`WRITERS`) and fails on any
  other; a workflow that needs `issues: write` or more is a separate,
  opt-in workflow (as `report.yml` is for `fuzz.yml`), because a reusable
  workflow cannot be granted more than its caller holds.
- **The docs-only gate is one job, copied identically.** Fifteen workflows
  carry the same `changes` job; `changes.yml` is the same gate for a
  package's own workflows. Change all copies together; the linter checks
  they match.
- **Artifacts are kept 7 days, and an upload never fails its job**
  (`continue-on-error: true`); see "Artifacts" in the README. The linter
  enforces both.
- **Tests run the real script.** A test extracts the `run:` of a step by its
  `id` (see `tests/check-report.sh`) rather than copying it. Write the test
  with the change, and break the change once to see the test fail.

## Checks to run before a pull request

```sh
python3 -m venv /tmp/ra && /tmp/ra/bin/pip install --quiet pyyaml
PATH="/tmp/ra/bin:$PATH" python3 tests/lint-workflows.py
PATH="/tmp/ra/bin:$PATH" bash tests/check-<area>.sh     # the ones you touched
```

Tests that need clang with libFuzzer or Linux tooling
(`check-keep-going.sh`, `check-native-reports.sh`, `check-alloc-*.sh`) run
in `self-test.yml`; locally, run them in a Linux container such as
`silkeh/clang:19`.

## Releasing

Semantic versioning, `vX.Y.Z`. Publishing a GitHub release `vX.Y.Z` moves the
major tag `vX` to it (`release.yml`); prereleases and releases older than the
newest in their line leave it alone. A new input or output is a minor
release; a fix is a patch. Write-token callers (`coverage.yml`,
`cran-release.yml`) are pinned by commit SHA in the packages, so they need a
release to reach them like everything else.

## Git and pull requests

- Branch from main; one topic per pull request; never push to main.
- Commit messages and PR bodies explain the change and how it was verified,
  with the numbers.
- A change that only touches documentation or `examples/` does not need the
  full self-test, but `tests/lint-workflows.py` always applies.
