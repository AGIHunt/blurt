#!/bin/zsh
# After a free-talk take: label it, review the unsure sentences, cut it, then open the mouthing step.
# Usage: ./talk.sh [session dir]   (default: newest session)
set -euo pipefail
dir="${0:A:h}"; base="$HOME/Library/Application Support/Blurt VSR Pilot"; run="$base/runtime"
session="${1:-$(ls -dt "$base"/rapid/sessions/*/ | head -1)}"; session="${session%/}"
"$run/asr-venv/bin/python" "$dir/free_label.py" "$session"
"$run/asr-venv/bin/python" "$dir/free_review.py" "$session"
"$run/asr-venv/bin/python" "$dir/free_label.py" "$session" --finish
"$run/model-venv/bin/python" "$dir/rapid_cut.py" "$session" --marks marks-reviewed.jsonl --no-asr
open -n "$base/RapidRecorder.app" --args --script "$session/shadow.json"
