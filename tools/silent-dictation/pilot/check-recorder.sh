#!/bin/zsh
set -euo pipefail
pilot_dir="${0:A:h}"
check_root="$(mktemp -d /tmp/blurt-recorder-check.XXXXXX)"
mkdir -p "$check_root/clips" "$check_root/pending"
ffmpeg -v error -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=6' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=6' \
  -c:v libx264 -c:a aac -shortest "$check_root/clips/draft-tone.mov"
python3 - "$check_root" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
takes = [dict(id=f'fixture-{i}', speaker_id='fixture', session_id='fixture',
              split='train', phrase_family='fixture', language='en', mode=mode,
              prompt='Synthetic software fixture, not participant data')
         for i, mode in enumerate(['voiced', 'silent', 'voiced'])]
(root / 'plan.json').write_text(json.dumps({'takes': takes}))
(root / 'pending/draft-tone.json').write_text(json.dumps({
    'take_id': 'fixture-0', 'filename': 'draft-tone.mov', 'audio_recorded': True,
    'context_source': 'regression_fixture'}))
PY
swiftc -D PILOT_CHECKS -parse-as-library "$pilot_dir/PilotRecorder.swift" \
  "$pilot_dir/Localization.swift" "$pilot_dir/RecorderChecks.swift" -o "$check_root/checks"
"$check_root/checks" "$check_root"
print -r -- "Inspect fixture results: $check_root"
