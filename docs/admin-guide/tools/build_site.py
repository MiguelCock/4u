"""Builds the web page of the admin guide from its Markdown and images.

docs/admin-guide/{es,en}/README.md and images/ become application/web/guide/,
which `flutter build web` carries to /admin/guide/. See README.md.

    uv run --no-project --with markdown==3.11.2 python build_site.py          # writes it
    uv run --no-project --with markdown==3.11.2 python build_site.py --check  # fails if out of date
"""

import html
import re
import shutil
import struct
import sys
from pathlib import Path

import markdown

HERE = Path(__file__).resolve().parent
GUIDE = HERE.parent
OUTPUT = GUIDE.parent.parent / "application" / "web" / "guide"

LANGUAGES = {
    "es": {"other": "en", "switch": "English", "index": "Contenido", "back": "Volver a la aplicación"},
    "en": {"other": "es", "switch": "Español", "index": "Contents", "back": "Back to the app"},
}

CSS = """
:root {
  --bg: #f8f9ff; --panel: #eef1f9; --text: #1a1c22; --muted: #565b68;
  --line: #d6dae5; --link: #2b5f9e; --mark: #d32f2f;
  color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14161b; --panel: #1e2129; --text: #e4e6ec; --muted: #a2a7b4;
    --line: #333844; --link: #9cc3f5;
  }
}
* { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 16px; }
body {
  margin: 0; background: var(--bg); color: var(--text);
  font: 16px/1.6 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}
a { color: var(--link); }
.layout { display: grid; grid-template-columns: 300px minmax(0, 1fr); }
nav {
  position: sticky; top: 0; height: 100vh; overflow-y: auto;
  background: var(--panel); border-right: 1px solid var(--line); padding: 20px;
}
nav .links { display: flex; justify-content: space-between; gap: 12px; margin-bottom: 16px; font-size: 14px; }
nav summary { font-weight: 600; margin-bottom: 8px; cursor: pointer; }
nav ul { list-style: none; margin: 0; padding: 0; }
nav ul ul { padding-left: 14px; font-size: 14px; }
nav li { margin: 5px 0; }
nav a { text-decoration: none; }
nav a:hover { text-decoration: underline; }
main { max-width: 1000px; padding: 32px 40px 80px; min-width: 0; }
h1 { font-size: 32px; line-height: 1.2; margin-top: 0; }
h2 { font-size: 26px; line-height: 1.25; margin-top: 56px; padding-top: 16px; border-top: 1px solid var(--line); }
h3 { font-size: 20px; margin-top: 36px; }
img { display: block; max-width: 100%; height: auto; border: 1px solid var(--line); border-radius: 8px; }
main > p > a:has(img), figure { display: block; margin: 16px 0; }
.scroll { overflow-x: auto; margin: 16px 0; }
table { border-collapse: collapse; width: 100%; font-size: 15px; }
th, td { border: 1px solid var(--line); padding: 7px 10px; text-align: left; vertical-align: top; }
th { background: var(--panel); }
td:first-child:not(:only-child) { white-space: nowrap; }
blockquote { margin: 16px 0; padding: 10px 16px; background: var(--panel); border-left: 4px solid var(--link); }
blockquote p { margin: 0; }
code { background: var(--panel); padding: 1px 5px; border-radius: 4px; font-size: 14px; }
@media (max-width: 800px) {
  .layout { display: block; }
  nav { position: static; height: auto; border-right: 0; border-bottom: 1px solid var(--line); padding: 14px 16px; }
  main { padding: 20px 16px 60px; }
  h1 { font-size: 26px; }
  h2 { font-size: 22px; }
}
@media print {
  nav { display: none; }
  .layout { display: block; }
  main { max-width: none; padding: 0; }
  img { break-inside: avoid; }
  h2 { break-after: avoid; }
}
"""


def _strip_tags(text):
    return html.unescape(re.sub(r"<[^>]+>", "", text))


def _index(body):
    """The side index: every chapter, with its sections, by their anchors."""
    items = []
    pending = None
    for match in re.finditer(
        r'<a id="([^"]+)"></a>|<h([23]) id="([^"]+)">(.*?)</h[23]>', body, re.S
    ):
        if match.group(1):
            pending = match.group(1)
            continue
        level, heading_id, title = match.group(2), match.group(3), match.group(4)
        items.append((int(level), pending or heading_id, _strip_tags(title)))
        pending = None
    lines = ["<ul>"]
    open_sub = False
    open_item = False
    for level, target, title in items:
        link = f'<a href="#{target}">{html.escape(title)}</a>'
        if level == 2:
            if open_sub:
                lines.append("</ul>")
                open_sub = False
            if open_item:
                lines.append("</li>")
            lines.append(f"<li>{link}")
            open_item = True
        else:
            if not open_sub:
                lines.append("<ul>")
                open_sub = True
            lines.append(f"<li>{link}</li>")
    if open_sub:
        lines.append("</ul>")
    if open_item:
        lines.append("</li>")
    lines.append("</ul>")
    return "\n".join(lines)


def _webp_size(path):
    """A lossy WebP's width and height, from its header."""
    data = path.read_bytes()[:30]
    if data[12:16] != b"VP8 ":
        raise ValueError(f"{path} isn't a lossy WebP")
    width, height = struct.unpack("<HH", data[26:30])
    return width & 0x3FFF, height & 0x3FFF


def _picture(match):
    """Pictures open larger on click and load only when reached. Their size
    keeps their space, or jumping to a section lands in the wrong place as the
    pictures above it load."""
    alt, source = match.groups()
    width, height = _webp_size(GUIDE / source.removeprefix("../"))
    return (
        f'<a href="{source}" target="_blank" rel="noopener">'
        f'<img alt="{alt}" src="{source}" width="{width}" height="{height}" '
        'loading="lazy"></a>'
    )


def _page(language):
    text = (GUIDE / language / "README.md").read_text(encoding="utf-8")
    body = markdown.markdown(text, extensions=["tables", "toc", "sane_lists"])
    title = _strip_tags(re.search(r"<h1[^>]*>(.*?)</h1>", body, re.S).group(1))
    body = re.sub(r'<img alt="([^"]*)" src="([^"]+)"\s*/?>', _picture, body)
    # Wide tables scroll on their own instead of the whole page.
    body = body.replace("<table>", '<div class="scroll"><table>').replace(
        "</table>", "</table></div>"
    )
    labels = LANGUAGES[language]
    return f"""<!doctype html>
<html lang="{language}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{CSS}</style>
</head>
<body>
<div class="layout">
<nav aria-label="{labels['index']}">
<div class="links">
<a href="../../">{labels['back']}</a>
<a href="../{labels['other']}/" hreflang="{labels['other']}">{labels['switch']}</a>
</div>
<details open>
<summary>{labels['index']}</summary>
{_index(body)}
</details>
</nav>
<main>
{body}
</main>
</div>
<script>if (innerWidth < 800) document.querySelector('nav details').open = false;</script>
</body>
</html>
"""


def _expected():
    """Every output file, by its path under guide/: text or bytes."""
    files = {
        "index.html": (
            '<!doctype html><meta charset="utf-8">'
            '<meta http-equiv="refresh" content="0; url=es/">'
            '<a href="es/">Guía de uso</a> · <a href="en/">User guide</a>\n'
        ).encode()
    }
    for language in LANGUAGES:
        files[f"{language}/index.html"] = _page(language).encode()
    for image in sorted((GUIDE / "images").rglob("*.webp")):
        files[str(image.relative_to(GUIDE))] = image.read_bytes()
    return files


def main():
    files = _expected()
    if "--check" in sys.argv[1:]:
        found = (
            {str(p.relative_to(OUTPUT)) for p in OUTPUT.rglob("*") if p.is_file()}
            if OUTPUT.exists()
            else set()
        )
        stale = sorted(found ^ set(files)) + sorted(
            path
            for path, content in files.items()
            if path in found and (OUTPUT / path).read_bytes() != content
        )
        if stale:
            print("The guide's page is out of date; run build_site.py:", *stale, sep="\n  ")
            sys.exit(1)
        print("The guide's page is up to date.")
        return
    shutil.rmtree(OUTPUT, ignore_errors=True)
    for path, content in files.items():
        target = OUTPUT / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    print(f"Wrote {len(files)} files to {OUTPUT}")


if __name__ == "__main__":
    main()
