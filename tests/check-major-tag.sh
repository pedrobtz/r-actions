#!/usr/bin/env bash
# The README tells consumers to pin `@v1` "to receive backwards-compatible
# updates automatically". That promise is only kept while v1 actually points
# at the newest release in the v1 line, and nothing enforced it: v1 once sat
# fourteen commits and four releases behind main, so every consumer pinned to
# it silently received none of them.
set -euo pipefail

major="${1:-v1}"

newest="$(git tag -l "${major}.*" | sort -V | tail -1)"
if [ -z "$newest" ]; then
  echo "No ${major}.* release tags found; nothing to compare against." >&2
  exit 1
fi

if ! git rev-parse -q --verify "refs/tags/${major}" >/dev/null; then
  echo "::error::${major} does not exist, but ${newest} does. Consumers pinned" \
       "to @${major} have nothing to resolve."
  exit 1
fi

major_sha="$(git rev-list -n1 "${major}")"
newest_sha="$(git rev-list -n1 "${newest}")"

if [ "$major_sha" != "$newest_sha" ]; then
  behind="$(git rev-list --count "${major}..${newest}")"
  echo "::error::${major} points at ${major_sha:0:8}, but the newest release" \
       "${newest} is ${newest_sha:0:8} -- ${behind} commits ahead. Consumers" \
       "pinned to @${major} are not receiving it. Move the tag:" \
       "git tag -f -a ${major} ${newest_sha} && git push --force origin ${major}"
  exit 1
fi

echo "${major} tracks ${newest} (${major_sha:0:8})."
