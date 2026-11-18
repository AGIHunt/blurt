#!/bin/zsh
# Local convenience wrapper. No cloud calls, installs, or automatic capture.
set -euo pipefail
pilot_dir="${0:A:h}"
pilot_home="$HOME/Library/Application Support/Blurt VSR Pilot"
pilot_runtime="${VSR_PILOT_RUNTIME:-$pilot_home/runtime}"
pilot_dataset="${VSR_PILOT_DATASET:-$pilot_home/datasets/speaker-01-tech-zh90-v1}"
pilot_command="${1:-open}"
if (( $# > 0 )); then shift; fi
case "$pilot_command" in
  open) open "$pilot_home/PilotRecorder.app" --args --dataset "$pilot_dataset" "$@" ;;
  audit) python3 "$pilot_dir/dataset.py" audit "$pilot_dataset" "$@" ;;
  prepare) python3 "$pilot_dir/pipeline.py" prepare "$pilot_dataset" \
    --probe "$pilot_runtime/vision_probe" --mean-face "$pilot_runtime/lipflow/lipflow/mean_face.npy" "$@" ;;
  adapt) "$pilot_runtime/model-venv/bin/python" "$pilot_dir/adapt.py" "$pilot_dataset" \
    --checkout "$pilot_runtime/lipflow" "$@" ;;
  evaluate) "$pilot_runtime/model-venv/bin/python" "$pilot_dir/pipeline.py" evaluate "$pilot_dataset" \
    --checkout "$pilot_runtime/lipflow" "$@" ;;
  compare) python3 "$pilot_dir/compare.py" "$@" ;;
  *) print -u2 'Usage: zsh run.sh open|audit|prepare|adapt|evaluate|compare [arguments]'; exit 2 ;;
esac
