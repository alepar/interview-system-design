#!/usr/bin/env python3
"""Drop /study-patterns 3X numbering from pattern file preambles.

Removes the "Pattern reference for `/study-patterns 3X`..." paragraph entirely.
Strips the " §3X" suffix from the Source line.
"""

import re
from pathlib import Path

PATTERN_DIR = Path("docs/coach/patterns")

PATTERN_REF_RE = re.compile(r'^Pattern reference for `/study-patterns [^`]+`\..*\n', re.MULTILINE)
SOURCE_RE = re.compile(r'(Source: `[^`]+`) §3[A-Z]\.')
MULTI_BLANK = re.compile(r'\n\n\n+')

changed = []
for f in sorted(PATTERN_DIR.glob("*.md")):
    content = f.read_text()
    new = PATTERN_REF_RE.sub('', content, count=1)
    new = SOURCE_RE.sub(r'\1.', new)
    new = MULTI_BLANK.sub('\n\n', new)
    if new != content:
        f.write_text(new)
        changed.append(f.name)

print(f"Updated {len(changed)} pattern files: {', '.join(changed)}")
