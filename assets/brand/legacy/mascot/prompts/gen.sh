#!/bin/zsh
# Renders one 1A animation sheet with the codex CLI's built-in image tool.
#   RAW=<dir> REFS=<dir with d1a-*.png> gen.sh <name> [extra reference …]   → $RAW/<name>.png
# The prompt is prompts/<name>.txt without its two comment lines (it was sent verbatim). Cut the sheet with
# assets/mascot/tools/cut.py.
D=${0:A:h}
name=$1; shift
imgs=(--image=$REFS/d1a-hero.png); for r in "$@"; do imgs+=("--image=$r"); done
p=$(tail -n +3 $D/$name.txt | sed "s|\$RAW|$RAW|g")
mkdir -p $RAW
codex exec --skip-git-repo-check -s workspace-write --add-dir $RAW -C $RAW --json "${imgs[@]}" "$p" < /dev/null > $RAW/$name.jsonl 2>&1
ls -la $RAW/$name.png 2>/dev/null || echo "MISSING $name"
