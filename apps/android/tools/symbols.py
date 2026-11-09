#!/usr/bin/env python3
"""Makes the app's icon fonts: Material Symbols Rounded, weight 300, cut down to the icons the app names.

    npm pack @material-symbols/font-300 && tar xzf material-symbols-font-300-*.tgz   # Apache-2.0, Google's fonts
    python3 apps/android/tools/symbols.py package/material-symbols-rounded.woff2

Reads the names from app/src/main/java/dev/blurt/remote/app/keys/Icons.kt (the values of `sf` and the `ui` list), and writes
app/src/main/res/font/symbols.ttf (FILL 0), symbols_fill.ttf (FILL 1) and keys/SymbolCodes.kt (name → code point). Needs fontTools and brotli.
"""
import pathlib
import re
import sys

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

here = pathlib.Path(__file__).resolve().parent.parent
icons = (here / "app/src/main/java/dev/blurt/remote/app/keys/Icons.kt").read_text()
names = set(re.findall(r'to "([a-z0-9_]+)(?:\|[a-z|]+)?"', icons))
ui = re.search(r"val ui: List<String> = listOf\((.*?)\)", icons, re.S).group(1)
names |= set(re.findall(r'"([a-z0-9_]+)"', ui))

src = TTFont(sys.argv[1])
cmap = src.getBestCmap()
rev = {v: k for k, v in cmap.items()}
ligs = {}
for lookup in src["GSUB"].table.LookupList.Lookup:
    for st in lookup.SubTable:
        st = getattr(st, "ExtSubTable", st)
        for first, ls in getattr(st, "ligatures", {}).items():
            for lig in ls:
                try:
                    ligs["".join(chr(rev[c]) for c in [first] + list(lig.Component))] = lig.LigGlyph
                except KeyError:
                    pass
missing = sorted(n for n in names if n not in ligs or ligs[n] not in rev)
if missing:
    sys.exit(f"not in the font: {missing}")
codes = {n: rev[ligs[n]] for n in sorted(names)}

res = here / "app/src/main/res/font"
res.mkdir(parents=True, exist_ok=True)
for fill, out in [(0, "symbols.ttf"), (1, "symbols_fill.ttf")]:
    f = instancer.instantiateVariableFont(TTFont(sys.argv[1]), {"FILL": fill})
    opts = subset.Options()
    opts.layout_features = []
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    s = subset.Subsetter(opts)
    s.populate(unicodes=list(codes.values()))
    s.subset(f)
    f.flavor = None
    f.save(res / out)

kt = here / "app/src/main/java/dev/blurt/remote/app/keys/SymbolCodes.kt"
lines = ",\n".join(f'        "{n}" to 0x{c:X}' for n, c in codes.items())
kt.write_text(
    "// Made by apps/android/tools/symbols.py from Icons.kt: the code point of each Material Symbol in res/font/symbols*.ttf.\n"
    "package dev.blurt.remote.app.keys\n\n"
    "object SymbolCodes {\n"
    "    val codes: Map<String, Int> = mapOf(\n"
    f"{lines},\n"
    "    )\n"
    "}\n"
)
print(f"{len(codes)} icons")
