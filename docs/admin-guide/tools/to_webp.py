"""Turns the screenshots' PNGs into WebP, and deletes the PNGs."""

import sys
from pathlib import Path

from PIL import Image

for png in Path(sys.argv[1]).rglob("*.png"):
    Image.open(png).convert("RGB").save(png.with_suffix(".webp"), quality=82, method=6)
    png.unlink()
