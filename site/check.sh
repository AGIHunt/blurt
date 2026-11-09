#!/bin/sh
# Checks that site/index.html and site/en/index.html are exactly what the generator writes: it runs
# blurt-media/site/src/build_pages9.py into a temporary folder (never over site/) and compares.
#
#   site/check.sh              # exit 0: the pages match; 1: they differ (the diff is printed); 0 with a note: no generator
#
# The generator lives outside this repo, in the founder's blurt-media folder. Set BLURT_MEDIA to its path if it
# isn't next to this checkout or at ~/workspace/blurt-media. Without it (open-source contributors) the check is
# skipped: change copy in both pages by hand, and say so in your pull request.
set -eu

site=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$site/.." && pwd)
# the main checkout, also from a worktree (.git/worktrees/<name> -> the repo that owns it)
main=$(cd "$repo" && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/.." 2>/dev/null && pwd || echo "$repo")

gen=""
for media in "${BLURT_MEDIA:-}" "$main/../blurt-media" "$repo/../blurt-media" "$HOME/workspace/blurt-media"; do
  if [ -n "$media" ] && [ -f "$media/site/src/build_pages9.py" ]; then
    gen="$(cd "$media/site/src" && pwd)/build_pages9.py"; break
  fi
done
if [ -z "$gen" ]; then
  echo "site/check.sh: skipped, the page generator (blurt-media/site/src/build_pages9.py) isn't on this machine."
  echo "Set BLURT_MEDIA=/path/to/blurt-media to run it."
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/blurt-site-check.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
# --stars keep: bake the star count already in each page, so the check is about the pages, not GitHub
python3 "$gen" --site "$site" --out "$tmp" --stars keep > /dev/null

status=0
for page in index.html en/index.html; do
  if ! cmp -s "$tmp/$page" "$site/$page"; then
    echo "site/$page differs from what $gen writes:"
    diff -u "$site/$page" "$tmp/$page" | head -80 || true
    status=1
  fi
done
if [ "$status" -eq 0 ]; then
  echo "site/check.sh: index.html and en/index.html match $gen"
else
  echo "Change the generator, not the pages; then run: python3 $gen --site $site --stars keep"
fi
exit "$status"
