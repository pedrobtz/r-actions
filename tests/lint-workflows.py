#!/usr/bin/env python3
"""Invariants for the reusable workflows in this repository.

Both of these were real failures, found by a consuming package rather than
here, which is the reason this file exists.
"""

import pathlib
import sys

import yaml

WORKFLOWS = pathlib.Path(".github/workflows")

# Workflows that legitimately write through the token, with the scopes each
# one needs. Anything else must be read-only.
WRITERS = {
    "coverage.yml": {"contents": "write"},
    "vendor-upstream.yml": {"contents": "read", "issues": "write"},
}

failures = []


def fail(workflow, message):
    failures.append(f"{workflow}: {message}")


RANK = {"none": 0, "read": 1, "write": 2}


def permissions_of(doc):
    """Top-level permissions, or the widest scope any single job asks for.

    Declaring scopes per job is stricter than declaring them once at the top,
    so a workflow that does it -- coverage.yml gives its badge job `write` and
    the other two `read` -- is summarised by the widest value per scope. Taking
    the last job's value instead would report whichever job happened to sort
    last, which is how the first version of this check accused coverage.yml of
    being read-only.
    """
    if "permissions" in doc:
        return doc["permissions"]

    widest = {}
    for job in (doc.get("jobs") or {}).values():
        if not isinstance(job, dict) or not isinstance(job.get("permissions"), dict):
            continue
        for scope, value in job["permissions"].items():
            if RANK.get(value, 0) >= RANK.get(widest.get(scope), -1):
                widest[scope] = value
    return widest or None


for path in sorted(WORKFLOWS.glob("*.yml")):
    name = path.name

    try:
        doc = yaml.safe_load(path.read_text())
    except yaml.YAMLError as exc:
        fail(name, f"does not parse: {exc}")
        continue

    if not isinstance(doc, dict) or not doc.get("jobs"):
        fail(name, "declares no jobs")
        continue

    # Cancelling superseded runs belongs to the caller. In a called workflow
    # `github.workflow` and `github.ref` are the caller's, so the usual group
    # expression here names the caller's own group -- which GitHub cancels as
    # a deadlock -- and the group of every sibling call in the same file, so
    # native-checks' six calls would cancel one another.
    # PyYAML reads the bare key `on` as the boolean True.
    triggers = doc.get("on", doc.get(True))
    if isinstance(triggers, dict) and "workflow_call" in triggers:
        where = ["the workflow"] if "concurrency" in doc else []
        where += [f"job `{j}`" for j, body in doc["jobs"].items()
                  if isinstance(body, dict) and "concurrency" in body]
        if where:
            fail(name, f"declares `concurrency` on {', '.join(where)}; a "
                       f"reusable workflow shares the caller's group names, "
                       f"so put it in the caller")

    perms = permissions_of(doc)

    # A reusable workflow cannot be granted more than its caller holds, and a
    # repository's default GITHUB_TOKEN permission is `read`. Asking for
    # `read-all` therefore rejects every caller that does not declare
    # permissions of its own -- as `startup_failure`, two seconds in, with no
    # jobs, no annotation and no log to read. It looks like an outage.
    if perms == "read-all":
        fail(name, "declares `permissions: read-all`, which breaks callers "
                   "that do not declare permissions of their own; name the "
                   "scopes it uses instead")
        continue

    if perms is None:
        fail(name, "declares no permissions; say what it needs explicitly")
        continue

    if not isinstance(perms, dict):
        fail(name, f"declares permissions as {perms!r}; use a scope mapping")
        continue

    expected = WRITERS.get(name)
    if expected is None:
        writes = sorted(s for s, v in perms.items() if v == "write")
        if writes:
            fail(name, f"asks for write on {', '.join(writes)} but is not "
                       f"listed in WRITERS; add it there if that is intended")
    elif perms != expected:
        fail(name, f"permissions {perms} do not match the declared "
                   f"expectation {expected}")

if failures:
    print("Workflow invariants violated:\n", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)

count = len(list(WORKFLOWS.glob("*.yml")))
print(f"{count} workflows: permissions are explicit, least-privilege and match WRITERS; no reusable workflow declares concurrency.")
