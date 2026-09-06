#!/usr/bin/env python3
"""Check the built site in `dist/` before it goes live.

The same idea as `Tools/blender/check_bundle.py`: nothing here has a compiler, so
the contract needs a test. Every rule below is one that fails silently in
production — a broken hreflang pair, malformed JSON-LD or a title nobody ever sees
in full costs traffic without ever raising an error.

    python3 web/build.py && python3 web/check.py
"""
import json
import pathlib
import re
import sys
from html.parser import HTMLParser

DOMAIN = "https://sensorstorm.ch"
# Google shows roughly 60 characters of a title and 155 of a description; below 50
# a description is usually too thin to be used at all.
TITLE_MAX = 65
DESC_RANGE = (50, 160)


class LinkParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hrefs: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag in ("a", "link"):
            for key, value in attrs:
                if key == "href" and value:
                    self.hrefs.append(value)


def check(dist: pathlib.Path) -> list[str]:
    pages = sorted(p for p in dist.rglob("*.html"))
    if not pages:
        return [f"no pages in {dist} — run build.py first"]

    problems: list[str] = []
    canonical: dict[str, str] = {}
    alternates: dict[str, dict[str, str]] = {}
    titles: dict[str, str] = {}
    descriptions: dict[str, str] = {}

    for page in pages:
        rel = page.relative_to(dist).as_posix()
        text = page.read_text(encoding="utf-8")

        match = re.search(r'<link rel="canonical" href="([^"]+)"', text)
        if not match:
            problems.append(f"{rel}: no canonical")
        else:
            canonical[rel] = match.group(1)

        # findall with two groups yields (hreflang, href) in that order.
        alternates[rel] = dict(re.findall(
            r'<link rel="alternate" hreflang="([^"]+)" href="([^"]+)"', text))
        if "x-default" not in alternates[rel]:
            problems.append(f"{rel}: no x-default hreflang")

        match = re.search(r"<title>(.*?)</title>", text, re.S)
        if not match:
            problems.append(f"{rel}: no title")
        else:
            titles[rel] = match.group(1)
            if len(titles[rel]) > TITLE_MAX:
                problems.append(f"{rel}: title {len(titles[rel])} chars > {TITLE_MAX}")

        match = re.search(r'<meta name="description" content="([^"]*)"', text)
        if not match:
            problems.append(f"{rel}: no meta description")
        else:
            descriptions[rel] = match.group(1)
            length = len(descriptions[rel])
            if not DESC_RANGE[0] <= length <= DESC_RANGE[1]:
                problems.append(f"{rel}: description {length} chars, want {DESC_RANGE}")

        for block in re.findall(
                r'<script type="application/ld\+json">(.*?)</script>', text, re.S):
            try:
                json.loads(block)
            except ValueError as error:
                problems.append(f"{rel}: invalid JSON-LD — {error}")

        if 'name="apple-itunes-app"' not in text:
            problems.append(f"{rel}: no Smart App Banner")
        if '<meta property="og:title"' not in text:
            problems.append(f"{rel}: no Open Graph title")

        parser = LinkParser()
        parser.feed(text)
        for href in parser.hrefs:
            if href.startswith(("http://", "https://", "mailto:", "#", "data:")):
                continue
            if not (page.parent / href).resolve().exists():
                problems.append(f"{rel}: broken link -> {href}")

    # Two pages sharing a title compete with each other for the same query.
    for label, table in (("title", titles), ("description", descriptions)):
        seen: dict[str, str] = {}
        for rel, value in table.items():
            if value in seen:
                problems.append(f"duplicate {label}: {rel} and {seen[value]}")
            seen[value] = rel

    # hreflang has to be reciprocal and point at the other page's canonical. A
    # one-sided pair is worse than none: it promises a translation at a URL that
    # does not claim to be one, and Google drops the whole cluster.
    for rel, alts in alternates.items():
        for lang, url in alts.items():
            if lang == "x-default":
                continue
            target = url.removeprefix(f"{DOMAIN}/")
            if target not in alternates:
                problems.append(f"{rel}: hreflang {lang} -> {target}, which does not exist")
            elif canonical.get(target) != url:
                problems.append(f"{rel}: hreflang {lang} -> {target}, whose canonical differs")
            elif rel not in {u.removeprefix(f"{DOMAIN}/") for u in alternates[target].values()}:
                problems.append(f"{rel}: hreflang {lang} -> {target} does not point back")

    for required in ("robots.txt", "sitemap.xml", "style.css"):
        if not (dist / required).exists():
            problems.append(f"missing {required}")

    listed = set(re.findall(rf"<loc>{re.escape(DOMAIN)}/([^<]+)</loc>",
                            (dist / "sitemap.xml").read_text(encoding="utf-8")))
    actual = {p.relative_to(dist).as_posix() for p in pages}
    for missing in sorted(actual - listed):
        problems.append(f"{missing}: not in sitemap.xml")
    for stale in sorted(listed - actual):
        problems.append(f"sitemap.xml lists {stale}, which was not built")

    print(f"checked {len(pages)} pages")
    return problems


def main() -> None:
    dist = pathlib.Path(__file__).resolve().parent / "dist"
    problems = check(dist)
    for problem in problems:
        print(f"  ✗ {problem}")
    print("ok" if not problems else f"{len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
