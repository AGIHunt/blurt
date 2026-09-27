# blurt promo video

A ~80s launch film, made entirely in code: [Remotion](https://remotion.dev) for picture, numpy for every sound effect,
Lyria 3 for the music bed and gpt-audio for the English voice-over and the babble (via OpenRouter), and
public-domain chicken recordings. Bilingual (EN / 中文) captions
are burned in. The product UI in the film is a fictional app ("Orbit"), no real data.

```bash
npm install
uv run audio/mix.py          # soundtrack: music edit on the beat grid + synthesized SFX + VO + ducking, -14 LUFS
npm run studio               # preview
npm run render               # -> out/blurt-promo.mp4
```

The published cut (`../assets/blurt-promo.mp4`) uses a voice re-timbred in CapCut (`audio/voice-edit.m4a`, the full
mix with the edited narration) plus the chicken layer:

```bash
npx remotion render src/index.ts Promo out/picture.mp4 --muted --crf=16
uv run audio/mix.py overlay audio/voice-edit.m4a public/soundtrack_jy.wav
ffmpeg -i out/picture.mp4 -i public/soundtrack_jy.wav -map 0:v -map 1:a -c:v copy -c:a aac -b:a 320k out/blurt-promo-chicken.mp4
```

`src/timeline.json` is the single source of truth: scene boundaries, voice-over starts, captions and every sound cue
(in seconds). Visuals and the mix both read it, so a cue moved there stays in sync everywhere.
Chicken calls are public-domain recordings (`audio/chicken/SOURCES.md`), placed by the `chicken` list in the
timeline; `uv run audio/mix.py overlay IN.wav OUT.wav` adds just that layer to an existing mix (e.g. one with an edited voice).
To regenerate music or voice lines: `OPENROUTER_API_KEY=… uv run audio/generate.py music|vo [v05 …]`.
