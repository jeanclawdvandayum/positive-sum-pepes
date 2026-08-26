#!/usr/bin/env python3
"""Build studio/dist/trait-studio.html — a single self-contained file.

Inlines index.html + app.css + every <script src> (compiler, defaults, app
modules) into ONE html file with zero external references. Works from
file:// and any static server.

Run from repo root:  python3 studio/tools/build_inline.py
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent  # repo root
SRC = ROOT / "studio" / "src"
DIST = ROOT / "studio" / "dist"
OUT = DIST / "trait-studio.html"


def read_asset(p: Path) -> str:
    """Read a css/js asset; literal '</script' inside would break the html
    parser once inlined, so refuse it loudly."""
    text = p.read_text(encoding="utf-8")
    if "</script" in text:
        raise SystemExit(f"FATAL: {p} contains '</script' — cannot inline")
    return text


def main() -> None:
    html = (SRC / "index.html").read_text(encoding="utf-8")

    # inline <link rel="stylesheet" href="X">
    def css_sub(m: "re.Match[str]") -> str:
        return "<style>\n" + read_asset(SRC / m.group(1)) + "\n</style>"

    html, n_css = re.subn(
        r'<link\s+rel="stylesheet"\s+href="([^"]+)"\s*/?>', css_sub, html
    )

    # inline <script src="X"></script> (src paths relative to studio/src/)
    def js_sub(m: "re.Match[str]") -> str:
        return "<script>\n" + read_asset((SRC / m.group(1)).resolve()) + "\n</script>"

    html, n_js = re.subn(
        r'<script\s+src="([^"]+)"\s*>\s*</script>', js_sub, html
    )

    # sanity: nothing external may remain
    offenders = re.findall(r'(?:src|href)="(http[^"]*|//[^"]*)"', html)
    if offenders:
        raise SystemExit(f"FATAL: external refs remain: {offenders}")
    if "PSPCompiler" not in html:
        raise SystemExit("FATAL: compiler code missing from bundle")
    if "__pspSelfTest" not in html:
        raise SystemExit("FATAL: self-test missing from bundle")

    DIST.mkdir(parents=True, exist_ok=True)
    OUT.write_text(html, encoding="utf-8")
    size = OUT.stat().st_size
    print(f"OK  wrote {OUT.relative_to(ROOT)}  ({size:,} bytes, "
          f"{n_css} stylesheet(s) + {n_js} script(s) inlined)")


if __name__ == "__main__":
    main()
