#!/usr/bin/env bash
# Downloads the .deb/.rpm assets of the most recent releases of every project in
# projects.txt into incoming/<owner>__<repo>/<tag>/.
# Needs the GitHub CLI (gh) with GH_TOKEN set (the workflow's own token is enough
# for public repositories).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../repo.conf
source "$ROOT/repo.conf"
INCOMING="${INCOMING:-$ROOT/incoming}"
mkdir -p "$INCOMING"

prerelease_flag=(--exclude-pre-releases)
[ "${INCLUDE_PRERELEASES:-false}" = "true" ] && prerelease_flag=()

grep -Ev '^\s*(#|$)' "$ROOT/projects.txt" | while read -r project _; do
  echo "== $project"
  tags=$(gh release list -R "$project" --limit "$KEEP_RELEASES" --exclude-drafts \
           "${prerelease_flag[@]}" --json tagName -q '.[].tagName')
  if [ -z "$tags" ]; then
    echo "   no releases yet, skipping"
    continue
  fi
  for tag in $tags; do
    dest="$INCOMING/${project/\//__}/$tag"
    mkdir -p "$dest"
    if out=$(gh release download "$tag" -R "$project" -p '*.deb' -p '*.rpm' \
               -D "$dest" --skip-existing 2>&1); then
      echo "   $tag: $(find "$dest" -type f | wc -l) package file(s)"
    elif grep -qi 'no assets' <<<"$out"; then
      echo "   $tag: no .deb/.rpm assets, skipping"
    else
      echo "$out" >&2
      exit 1
    fi
  done
done
