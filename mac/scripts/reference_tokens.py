# Token IDs from Hugging Face `tokenizers` (what sentence-transformers uses) for text that
# GemmaTokenizer must get exactly right: emoji sequences, combining and precomposed accents,
# runs of spaces and newlines, scripts other than Latin, characters only byte fallback can
# encode, and seeded random Unicode.
#
#   uv run --with tokenizers==0.22.1 python -I mac/scripts/reference_tokens.py
#
# Writes mac/Packages/AppearsModel/Tests/GemmaEmbedderTests/Resources/reference-tokens.json.
# Texts are stored as code points so nothing normalizes them on the way into Swift.

import json
import random
from pathlib import Path

from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "mac/Models/appears-model/tokenizer.json"
OUT = ROOT / "mac/Packages/AppearsModel/Tests/GemmaEmbedderTests/Resources/reference-tokens.json"

EDGE = [
    " ", "  ", "a", "a" * 45, "\n" * 40, "\t\t\t\t x", " " * 45 + "end", "trailing space ", " leading",
    "café", "café", "é́́", "Ångström", "naïve façade", "ﬁ ligature", "Ⅻ ①",
    "👍", "👍🏽", "👩‍👩‍👧‍👦 family", "🏳️‍🌈", "🇨🇦🇺🇸", "❤️‍🔥", "🫠🫥", "😂" * 8,
    "東京で会いましょう", "你好，明天见", "안녕하세요", "مرحبا كيف حالك", "שלום", "हिन्दी", "ภาษาไทย",
    " private use", "\U0010fffd", "​ zero width", "­ soft", "﻿bom ﻿﻿", "\x01\x07 ctrl",
    "https://maps.apple.com/?address=2401%20Harrison%20St&ll=37.75,-122.41", "+1 (415) 555-0123", "$1,234.56",
    "ok\r\nnext\rline", "ALLCAPS SHOUTING!!!", "lol.......", "????!!!!", "—–-‐", "“smart” ‘quotes’", "…", "©®™ °C ±5",
    "title: Dinner crew · Mar 12, 2026 | text: Sierra: 2401 Harrison St 🍝\nMe: perfect,  see you there!!",
]

POOLS = [range(0x20, 0x7F), range(0xA0, 0x250), range(0x300, 0x370), range(0x400, 0x500), range(0x590, 0x700),
         range(0x900, 0x980), range(0x3040, 0x3100), range(0x4E00, 0x4F00), range(0xAC00, 0xAD00),
         range(0x1F300, 0x1F700), [0x200D, 0xFE0F, 0x20, 0x20, 0x20, 0xA, 0x9, 0x1F3FB, 0x1F3FF, 0xFEFF],
         range(0xE000, 0xE010), range(0x10000, 0x10100)]


def main() -> None:
    rnd = random.Random(7)
    texts = EDGE + [
        "".join(chr(rnd.choice(rnd.choice(POOLS))) for _ in range(rnd.choice([1, 2, 3, 5, 8, 20, 60, 200])))
        for _ in range(300)
    ]
    tokenizer = Tokenizer.from_file(str(MODEL))
    cases = [{"codepoints": [ord(c) for c in text], "ids": tokenizer.encode(text).ids} for text in texts]
    OUT.write_text(json.dumps({"cases": cases}, separators=(",", ":")) + "\n")
    print(f"Wrote {len(cases)} cases to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
