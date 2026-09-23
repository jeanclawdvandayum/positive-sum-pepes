#!/usr/bin/env python3
"""Build the 420 edition's single-file pages.

  studio-420/src/index.html       -> studio-420/dist/trait-studio-420.html
  studio-420/src/collection.html  -> studio-420/dist/collection.html

Inlines the html + app.css + every <script src> (compiler, defaults, app
modules) into ONE html file with zero external references. Works from
file:// and any static server.

Run from anywhere:  python3 studio-420/tools/build_inline.py
"""
import re
from pathlib import Path

STUDIO = Path(__file__).resolve().parent.parent  # studio-420
SRC = STUDIO / "src"
DIST = STUDIO / "dist"
PAGES = [
    ("index.html", "trait-studio-420.html", ("__pspSelfTest",)),
    ("collection.html", "collection.html", ("PSP_ORIGINAL", "PSP_DEFAULTS")),
]


def read_asset(p: Path) -> str:
    """Read a css/js asset; literal '</script' inside would break the html
    parser once inlined, so refuse it loudly."""
    text = p.read_text(encoding="utf-8")
    if "</script" in text:
        raise SystemExit(f"FATAL: {p} contains '</script' — cannot inline")
    return text


def build(src_name: str, out_name: str, must_have) -> None:
    html = (SRC / src_name).read_text(encoding="utf-8")

    def css_sub(m: "re.Match[str]") -> str:
        return "<style>\n" + read_asset(SRC / m.group(1)) + "\n</style>"

    html, n_css = re.subn(
        r'<link\s+rel="stylesheet"\s+href="([^"]+)"\s*/?>', css_sub, html
    )

    # <script src="X"></script>, src relative to studio-420/src/
    def js_sub(m: "re.Match[str]") -> str:
        return "<script>\n" + read_asset((SRC / m.group(1)).resolve()) + "\n</script>"

    html, n_js = re.subn(
        r'<script\s+src="([^"]+)"\s*>\s*</script>', js_sub, html
    )

    offenders = re.findall(r'(?:src|href)="(http[^"]*|//[^"]*)"', html)
    if offenders:
        raise SystemExit(f"FATAL: external refs remain in {out_name}: {offenders}")
    leftover = re.findall(r'<script\s+src=', html)
    if leftover:
        raise SystemExit(f"FATAL: un-inlined <script src> in {out_name}")
    for token in ("PSPCompiler",) + tuple(must_have):
        if token not in html:
            raise SystemExit(f"FATAL: {token} missing from {out_name}")

    DIST.mkdir(parents=True, exist_ok=True)
    out = DIST / out_name
    out.write_text(html, encoding="utf-8")
    print(f"OK  wrote {out.relative_to(STUDIO.parent)}  ({out.stat().st_size:,} bytes, "
          f"{n_css} stylesheet(s) + {n_js} script(s) inlined)")


def main() -> None:
    for src_name, out_name, must in PAGES:
        build(src_name, out_name, must)


if __name__ == "__main__":
    main()
