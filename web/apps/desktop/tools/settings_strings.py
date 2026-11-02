#!/usr/bin/env python3
"""Settings' words for the Windows / Linux app, from the Mac's own: Resources/{en,zh-Hans}.lproj/*.strings →
web/apps/desktop/src/locales/settings.{en,zh-Hans}.json as "st.<the Mac's key>" (docs/design/windows-parity/settings.md).
Mac-only words become Windows ones (⌘ → Ctrl, Finder → File Explorer, Keychain → Windows Credential Manager …); the
sentences that can't be swapped word for word, and the few Windows-only ones ("win.*"), are in
settings_strings.overrides.json. Change those, or the Mac's strings, and run this again — never edit the output."""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../..'))
RES = os.path.join(ROOT, 'skills/blurt/recorder/macos/Sources/BlurtApp/Resources')


def load(lang):
    out = {}
    for f in sorted(glob.glob(f'{RES}/{lang}.lproj/*.strings')):
        table = os.path.basename(f)[:-len('.strings')]
        for m in re.finditer(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', open(f, encoding='utf-8').read(), re.M):
            out[f'{table}:{m.group(1)}'] = m.group(2)
    return out


EN, ZH = load('en'), load('zh-Hans')
d = {k: [v, ZH.get(k)] for k, v in EN.items()}
PATTERNS = [
 r'^Settings:settings\.(group|kit|search|kw)\.',
 r'^Settings:settings\.general\.',
 r'^Settings:settings\.(projects|privacy|storage|screen_text|perm)\.',
 r'^Dictation:dictation\.(settings|mode|sounds|stop_sound|style|translate|history|models|key|mic|vocab|text\.section|data\.section)',
 r'^Capture:capture\.(action|keys)\.',
 r'^Speech:speech\.',
 r'^Models:models\.',
 r'^Main:(main\.sidebar\.projects|app\.menu\.(updates|update_to)|main\.project\.rename|main\.project\.remove)$',
 r'^Main:action\.reveal_in_finder$',
 r'^Terminal:(agents|install)\.',
 r'^Dictation:dictation\.feedback\.',
 r'^Main:(app\.contract\.|app\.update\.|main\.job\.hint\.interrupted)',
 r'^Common:(project\.inbox|action\.(cancel|ok|done))$',
 r'^Dictation:dictation\.(only_my_voice|voiceprint\.|polish\.)',
 r'^Main:app\.menu\.(countdown|after\.)',
]
pat = [re.compile(p) for p in PATTERNS]
def conv(s):
    n = [0]
    def rep(m):
        if m.group(0) == '%%': return '%'
        pos = m.group(1)
        if pos: return '{' + pos + '}'
        n[0] += 1
        return '{' + str(n[0]) + '}'
    return re.sub(r'%%|%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcCsSpaA]', rep, s)
GLYPH = {'⌃': 'Ctrl', '⌥': 'Alt', '⇧': 'Shift', '⌘': 'Ctrl'}
KEYNAME = {'↩': 'Enter', '⌫': 'Backspace', '⎋': 'Esc'}
# Blurt's own capture keys: ⌥ + the letter on the Mac, Alt+Shift + the same letter here (hotkeys.rs default_key)
CAPTURE_KEYS = 'RBPADVOCTHLM'


def keys(s):
    """⌘Z → Ctrl+Z, ⇧⌘3 → Ctrl+Shift+3 (Windows' order), ⌥C → Alt+Shift+C (a capture key), ⌘↩ → Ctrl+Enter; a glyph
    naming its own key (⌥ Option) → that key's name; a lone glyph → the key's name."""
    def combo(m):
        mods, key = m.group(1), m.group(2)
        if mods == '⌥' and key in CAPTURE_KEYS:
            return f'Alt+Shift+{key}'
        names = [n for g, n in (('⌃', 'Ctrl'), ('⌘', 'Ctrl'), ('⌥', 'Alt'), ('⇧', 'Shift')) if g in mods]
        names = list(dict.fromkeys(names))
        return '+'.join(names + [KEYNAME.get(key, key)])
    s = re.sub(r'[⌃⌥⇧⌘] ?(Control|Option|Shift|Command)', lambda m: {'Control': 'Ctrl', 'Option': 'Alt', 'Shift': 'Shift', 'Command': 'Ctrl'}[m.group(1)], s)
    s = re.sub(r'([⌃⌥⇧⌘]+)(空格|Space|Esc|Tab|F\d{1,2}|[A-Z0-9↩⌫⎋=\-\[\]/])', combo, s)  # not , . ; — after a glyph they end the sentence
    return re.sub(r'[⌃⌥⇧⌘]', lambda m: GLYPH[m.group(0)], s)


def winify(s, zh):
    s = s.replace('\\"', '"').replace('\\n', '\n')
    rep = [('macOS', 'Windows'), ('this Mac', 'this PC'), ('This Mac', 'This PC'), ('the Mac', 'the PC'), ('your Mac', 'your PC'), ('Your Mac', 'Your PC'),
           ('Finder', 'File Explorer'), ('访达', '文件资源管理器'), ('Keychain', 'Windows Credential Manager'), ('钥匙串', 'Windows 凭据管理器'),
           ('System Settings', 'Windows Settings'), ('系统设置', 'Windows 设置'),
           ('Move to Trash', 'Delete'), ('废纸篓', '回收站'), ('Trash', 'Recycle Bin')]
    for a, b in rep: s = s.replace(a, b)
    s = keys(s).replace('Option', 'Alt')
    # one path separator, as the Windows-only strings write it: Settings → Shortcuts
    s = re.sub(r'(\S) > (\S)', r'\1 → \2', s)
    if zh: s = re.sub(r'([\u4e00-\u9fff])(Windows|Ctrl|Alt|Shift)', r'\1 \2', s)
    return s
out_en, out_zh, seen = {}, {}, {}
for k, (en, zh) in d.items():
    if not any(p.search(k) for p in pat): continue
    key = k.split(':', 1)[1]
    if re.search(r'_(zero|one|two|few|many|other)$', key): continue   # read as plural forms by @blurt/i18n
    if key in seen: print('dup', k, seen[key], file=sys.stderr); continue
    seen[key] = k
    out_en['st.' + key] = winify(conv(en), False)
    out_zh['st.' + key] = winify(conv(zh or en), True)
ov = json.load(open(os.path.join(HERE, 'settings_strings.overrides.json'), encoding='utf-8'))
for k, (en, zh) in ov.items():
    out_en['st.' + k] = en; out_zh['st.' + k] = zh
# the same placeholders on both sides (a zh string may name fewer)
for k in out_en:
    a = set(re.findall(r'\{(\w+)\}', out_en[k])); b = set(re.findall(r'\{(\w+)\}', out_zh[k]))
    if a != b: print('ph', k, a, b, file=sys.stderr)
D = os.path.join(HERE, '../src/locales/')
json.dump(dict(sorted(out_en.items())), open(D + 'settings.en.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
json.dump(dict(sorted(out_zh.items())), open(D + 'settings.zh-Hans.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print(len(out_en))
