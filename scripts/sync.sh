#!/usr/bin/env bash
# Mirrors https://s3.amazonaws.com/lucidestatic/ into the repo root.
#
# The site is a Vite build with content-hashed filenames, so the exact file
# set changes on every rebuild. This script discovers files by crawling:
#   index.html -> its script/link refs -> every quoted "*.js"/"*.css" relative
#   path found inside those files (this also picks up Vite's __vite__mapDeps
#   dynamic-import manifest arrays, which reference chunks/assets that are
#   NOT linked directly from index.html) -> repeat until no new files appear.
# It then replaces the tracked site files wholesale, since stale hashed
# files from a previous build must be removed, not merged.
set -uo pipefail

BASE="https://s3.amazonaws.com/lucidestatic"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

declare -A seen
queue=()

enqueue() {
  local rel="$1"
  rel="$(realpath -m --relative-to="$STAGE" "$STAGE/$rel")"
  if [[ -z "${seen[$rel]:-}" ]]; then
    seen["$rel"]=1
    queue+=("$rel")
  fi
}

fetch() {
  local rel="$1"
  local dest="$STAGE/$rel"
  mkdir -p "$(dirname "$dest")"
  if ! curl -sf "$BASE/$rel" -o "$dest"; then
    echo "warn: failed to fetch $rel (skipping)" >&2
    rm -f "$dest"
    return 1
  fi
}

# 1. index.html
curl -sf "$BASE/index.html" -o "$STAGE/index.html" || { echo "fatal: could not fetch index.html" >&2; exit 1; }

# 2. seed queue from index.html src="..."/href="..." refs
while IFS= read -r ref; do
  enqueue "$ref"
done < <(grep -oE '(src|href)="[A-Za-z0-9_./-]+\.(js|css)"' "$STAGE/index.html" | sed -E 's/^(src|href)="//; s/"$//')

# 3. BFS: fetch each queued file, then discover further refs inside it,
#    resolved relative to that file's own directory.
i=0
while [[ $i -lt ${#queue[@]} ]]; do
  rel="${queue[$i]}"
  i=$((i+1))
  fetch "$rel" || continue
  dir="$(dirname "$rel")"
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    enqueue "$dir/$ref"
  done < <(grep -oE '"[A-Za-z0-9_./-]+\.(js|css)"' "$STAGE/$rel" | tr -d '"')
done

fetched=$(find "$STAGE" -type f | wc -l)
echo "Fetched $fetched files"

if [[ $fetched -lt 2 ]]; then
  echo "fatal: suspiciously few files fetched, aborting without touching repo" >&2
  exit 1
fi

# 4. replace tracked site files wholesale (keep .git, .github, scripts/, .gitattributes)
find "$REPO_ROOT" -maxdepth 1 -mindepth 1 \
  ! -name '.git' ! -name '.github' ! -name 'scripts' ! -name '.gitattributes' \
  -exec rm -rf {} +
cp -r "$STAGE"/. "$REPO_ROOT"/

echo "Sync complete."
