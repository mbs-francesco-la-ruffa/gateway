"""Checks one rendered maintenance page against what it must contain (tests/check.sh).

    python3 tests/page_check.py <page.html> '<expectations as JSON>'

Expectations, every key optional:
  lang, title, h1, status        exact text (HTML entities decoded)
  texts / absent                 phrases that must / must not appear in the visible text
  hrefs                          the exact list of link targets, in order
  img                            the logo's src, or null for no image
  until                          the <time datetime>, or null for none
  contrast                       true: measure every colour pair in both themes
  tokens                         {"color-primary": ["#light", "#dark"], ...}: the token in each theme
  radius / font                  the --radius value / the start of the --font-sans stack

Always checked as well: below the token blocks the style writes no colour, length or font of its own.

Always checked: one <main>, one <h1>, one <script> (the page's own), no tag beyond the ones the template
uses, every id unique, every aria-labelledby pointing at an id, the only event handler the logo's.
Prints one line per failure and exits 1 if any.
"""
import json
import re
import sys
from html.parser import HTMLParser

ALLOWED_TAGS = {
    "html", "head", "meta", "title", "style", "body", "main", "div", "p", "span", "h1", "h2", "a", "svg",
    "path", "circle", "rect", "img", "time", "section", "ul", "li", "footer", "script", "br",
}
VOID = {"meta", "img", "br"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags = []  # (tag, attrs dict)
        self.stack = []
        self.text = {}  # tag id -> text, for title/h1/status
        self.visible = []
        self.style = ""
        self.in_style = self.in_script = self.in_title = False
        self.current = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        self.tags.append((tag, a))
        if tag not in VOID:
            self.stack.append((tag, a, len(self.visible)))
        self.in_style |= tag == "style"
        self.in_script |= tag == "script"

    def handle_startendtag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))

    def handle_endtag(self, tag):
        while self.stack:
            t, a, start = self.stack.pop()
            chunk = " ".join(self.visible[start:]).strip()
            key = t if t in ("title", "h1") else ("status" if "status" in a.get("class", "").split() else None)
            if key and key not in self.text:
                self.text[key] = re.sub(r"\s+", " ", chunk)
            if t == tag:
                break
        if tag == "style":
            self.in_style = False
        if tag == "script":
            self.in_script = False

    def handle_data(self, data):
        if self.in_style:
            self.style += data
        elif not self.in_script:
            self.visible.append(data)


def hex_rgb(value):
    value = value.strip().lower()
    if not re.fullmatch(r"#[0-9a-f]{6}", value):
        raise ValueError(f"not a #rrggbb colour: {value!r}")
    return tuple(int(value[i:i + 2], 16) for i in (1, 3, 5))


def luminance(rgb):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def mix(top, bottom, alpha):
    return tuple(round(t * alpha + b * (1 - alpha)) for t, b in zip(top, bottom))


def themes(style):
    """The custom properties of :root, and of :root under prefers-color-scheme: dark on top of them."""
    def block(text):
        return dict(re.findall(r"--([a-z-]+):\s*(#[0-9a-fA-F]{6})\s*;", text))
    root = re.search(r"^:root\s*\{(.*?)\}", style, re.S | re.M)
    dark = re.search(r"prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{(.*?)\}", style, re.S)
    if not root or not dark:
        raise ValueError("no :root block, or no dark :root block, in the page's style")
    light = block(root.group(1))
    return {"light": light, "dark": {**light, **block(dark.group(1))}}


# (foreground, background, minimum), on the frontend's token names: text asks 4.5 (WCAG 1.4.3 AA), a
# control's edge or the focus ring 3 (1.4.11). The badge's ink sits on its own surface, the hover fill
# under the ink, the expected time on the card.
PAIRS = [
    ("color-foreground", "color-background", 4.5), ("color-foreground", "color-card", 4.5),
    ("color-foreground", "color-accent", 4.5), ("color-heading", "color-background", 4.5),
    ("color-muted-foreground", "color-background", 4.5), ("color-muted-foreground", "color-card", 4.5),
    ("color-primary-foreground", "color-primary", 4.5),
    ("color-caution", "color-caution-surface", 4.5), ("color-negative", "color-negative-surface", 4.5),
    ("color-control", "color-background", 3), ("color-primary-edge", "color-background", 3),
    ("color-ring", "color-background", 3),
]


def check_contrast(style, failures, report):
    for name, colours in themes(style).items():
        rgb = {k: hex_rgb(v) for k, v in colours.items()}
        worst = []
        for fg, bg, minimum in PAIRS:
            if fg not in rgb or bg not in rgb:
                failures.append(f"{name}: no --{fg} or --{bg} in the page's tokens")
                continue
            r = ratio(rgb[fg], rgb[bg])
            worst.append(f"{fg}/{bg} {r:.2f}")
            if r < minimum:
                failures.append(f"{name}: {fg} on {bg} is {r:.2f}:1, below {minimum}:1 (primary {colours.get('color-primary')})")
        report.append(f"{name}: " + ", ".join(worst))


def check_tokens(style, failures):
    """Below the token blocks, the style names no colour, length or font of its own: every value is a var()."""
    rules = style[style.index("*, *::before"):] if "*, *::before" in style else style
    rules = re.sub(r"@media[^{]*", "", rules)  # a media query cannot read a custom property
    for colour in re.findall(r"#[0-9a-fA-F]{3,8}\b|\b(?:rgb|hsl)a?\((?!0 0 0 / )", rules):
        failures.append(f"a colour written outside the tokens: {colour}")
    for length in re.findall(r"(?<![\w.-])\d*\.?\d+(?:rem|em)\b", rules):
        failures.append(f"a length written outside the tokens: {length}")
    if re.search(r"font-family:(?!\s*var\()", rules):
        failures.append("a font family written outside the tokens")


def main():
    path, expect = sys.argv[1], json.loads(sys.argv[2])
    with open(path, encoding="utf-8") as f:
        page = Page()
        page.feed(f.read())
    failures, report = [], []
    tags = page.tags
    names = [t for t, _ in tags]
    visible = re.sub(r"\s+", " ", " ".join(page.visible))

    def one(tag):
        if names.count(tag) != 1:
            failures.append(f"{names.count(tag)} <{tag}>, expected one")

    for tag in ("main", "h1", "script", "title", "html"):
        one(tag)
    stray = sorted(set(names) - ALLOWED_TAGS)
    if stray:
        failures.append(f"tags the template never writes: {stray}")
    ids = [a["id"] for _, a in tags if "id" in a]
    if len(ids) != len(set(ids)):
        failures.append(f"an id used twice: {ids}")
    for _, a in tags:
        for ref in a.get("aria-labelledby", "").split():
            if ref not in ids:
                failures.append(f"aria-labelledby names [{ref}], which no element has")
        for attr in a:
            if attr.startswith("on") and not (attr == "onerror" and a[attr] == "this.remove()"):
                failures.append(f"an event handler attribute: {attr}={a[attr]!r}")
    html = next(a for t, a in tags if t == "html")

    if "lang" in expect and html.get("lang") != expect["lang"]:
        failures.append(f"lang is {html.get('lang')!r}, expected {expect['lang']!r}")
    for key in ("title", "h1", "status"):
        if key in expect and page.text.get(key) != expect[key]:
            failures.append(f"{key} is {page.text.get(key)!r}, expected {expect[key]!r}")
    for phrase in expect.get("texts", []):
        if phrase not in visible:
            failures.append(f"missing text: {phrase!r}")
    for phrase in expect.get("absent", []):
        if phrase in visible:
            failures.append(f"text that must not be there: {phrase!r}")
    if "hrefs" in expect:
        hrefs = [a.get("href") for t, a in tags if t == "a"]
        if hrefs != expect["hrefs"]:
            failures.append(f"links are {hrefs}, expected {expect['hrefs']}")
    if "img" in expect:
        srcs = [a.get("src") for t, a in tags if t == "img"]
        if srcs != ([] if expect["img"] is None else [expect["img"]]):
            failures.append(f"images are {srcs}, expected {expect['img']!r}")
    if "until" in expect:
        times = [a.get("datetime") for t, a in tags if t == "time"]
        if times != ([] if expect["until"] is None else [expect["until"]]):
            failures.append(f"<time> elements are {times}, expected {expect['until']!r}")
    check_tokens(page.style, failures)
    for key, value in expect.get("tokens", {}).items():
        light, dark = (themes(page.style)[t].get(key) for t in ("light", "dark"))
        if [light, dark] != value:
            failures.append(f"--{key} is {light} light, {dark} dark, expected {value}")
    if "radius" in expect and f"--radius: {expect['radius']};" not in page.style:
        failures.append(f"--radius is not {expect['radius']}")
    if "font" in expect and not re.search(r"--font-sans: " + re.escape(expect["font"]), page.style):
        failures.append(f"--font-sans does not start with {expect['font']}")
    if expect.get("contrast"):
        try:
            check_contrast(page.style, failures, report)
        except ValueError as error:
            failures.append(str(error))

    for line in failures:
        print(line)
    if report and not failures and expect.get("verbose"):
        print("\n".join(report))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
