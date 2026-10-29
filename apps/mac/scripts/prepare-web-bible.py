#!/usr/bin/env python3
"""Convert eBible.org's engwebp_vpl.zip into the bundled, offline Bible.

Usage: python3 scripts/prepare-web-bible.py /path/to/engwebp_vpl.zip
Source: https://ebible.org/Scriptures/engwebp_vpl.zip
The World English Bible text is public domain. Only book identifiers change;
verse text is retained verbatim. Five empty source verse slots are omitted.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

codes = dict(EZE="EZK", JOE="JOL", NAH="NAM", SOL="SNG", MAR="MRK", JOH="JHN", PHI="PHP", JAM="JAS")
codes.update({"1JO": "1JN", "2JO": "2JN", "3JO": "3JN"})
with zipfile.ZipFile(sys.argv[1]) as archive:
    source = archive.read("engwebp_vpl.txt")
verses = []
for line in source.decode("utf-8-sig").splitlines():
    match = re.fullmatch(r"([A-Z0-9]+) (\d+):(\d+) (.*)", line)
    if not match:
        raise ValueError(f"Unexpected source line: {line!r}")
    book, chapter, verse, text = match.groups()
    if text.strip():
        verses.append(dict(book=codes.get(book, book), chapter=int(chapter), verse=int(verse), text=text))
data = dict(formatVersion=1, id="WEB", name="World English Bible (Updated, 66 books)", language="en",
            copyright="World English Bible — Public Domain. Text: eBible.org.",
            source="https://ebible.org/Scriptures/details.php?id=engwebp", verses=verses)
destination = Path(__file__).resolve().parent.parent / "Packages/BibleKit/Sources/BibleKit/Resources/WEB.json"
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
print(f"{len(verses)} verses, {len({v['book'] for v in verses})} books")
print(f"Source text SHA256: {hashlib.sha256(source).hexdigest()}")
