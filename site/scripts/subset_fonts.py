#!/usr/bin/env python3
"""按官网实际用到的字符裁剪 Noto Serif SC，输出自托管的 woff2。

官网文案变动后重新运行。依赖 fonttools 与 brotli：

    pip install fonttools brotli
    python3 site/scripts/subset_fonts.py /path/to/NotoSerifSC[wght].ttf

源字体取自 https://github.com/google/fonts/tree/main/ofl/notoserifsc（SIL OFL 1.1）。
输出 designs/website/fonts/NotoSerifSC-subset.woff2，以及记录已收录字符的
NotoSerifSC-subset.chars.txt；site/build.mjs 用后者检查是否有新字未收录。
"""

import re
import sys
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = Path(__file__).resolve().parents[2]
WEBSITE = ROOT / "designs" / "website"
OUT_DIR = WEBSITE / "fonts"
OUT_FONT = OUT_DIR / "NotoSerifSC-subset.woff2"
OUT_CHARS = OUT_DIR / "NotoSerifSC-subset.chars.txt"

# 页面里用到的字重范围：500（英文副标题）到 900（大标题）
WEIGHT_RANGE = (500, 900)


def page_chars() -> str:
    html = (WEBSITE / "index.html").read_text(encoding="utf-8")
    text = re.sub(r"<[^>]+>", " ", html)
    ascii_printable = "".join(chr(c) for c in range(0x20, 0x7F))
    chars = set(text) | set(ascii_printable) | set("，。、；：？！“”‘’（）《》—…·")
    return "".join(sorted(c for c in chars if c.isprintable()))


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    font = TTFont(sys.argv[1])
    chars = page_chars()
    options = subset.Options()
    options.flavor = "woff2"
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=chars)
    subsetter.subset(font)
    # 先裁字符再收窄字重轴；反过来做时 fontTools 会在惰性加载的 gvar 上报 KeyError
    font = instancer.instantiateVariableFont(font, {"wght": WEIGHT_RANGE})

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    font.flavor = "woff2"
    # 保留源字体的时间戳，文案不变时输出逐字节一致
    font.recalcTimestamp = False
    font.save(OUT_FONT)
    OUT_CHARS.write_text(chars, encoding="utf-8")
    print(f"{OUT_FONT.relative_to(ROOT)}: {len(chars)} chars, {OUT_FONT.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
