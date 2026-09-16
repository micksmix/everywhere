import hashlib
import html
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
from urllib.parse import urlsplit, urlunsplit

root = Path(__file__).resolve().parent.parent
output = Path(sys.argv[1]).resolve()
pandoc = shutil.which("pandoc")
if not pandoc:
    sys.exit("Building Everywhere Help requires Pandoc. Install it with: brew install pandoc")

pages = {
    "docs/USER_GUIDE.md": ("index.html", "Everywhere Help"),
    "README.md": ("overview.html", "Overview and installation"),
    "docs/SEARCH_PERFORMANCE.md": ("performance.html", "Search performance"),
}
resources = output / "Contents/Resources/en.lproj"
resources.mkdir(parents=True, exist_ok=True)
stylesheet = (root / "Resources/Help/help.css").read_text()
(resources / "help.css").write_text(stylesheet)
nav = '<nav aria-label="Help pages">' + " · ".join(
    f'<a href="{name}">{title}</a>' for name, title in pages.values()
) + ' · <a href="license.html">License</a></nav>'


def document(title, body):
    return f'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="AppleTitle" content="Everywhere Help">
<meta name="description" content="{html.escape(title)}: Everywhere file search for macOS.">
<title>{html.escape(title)}</title><link rel="stylesheet" href="help.css">
</head><body>{nav}<main>{body}</main></body></html>
'''


for source, (name, title) in pages.items():
    body = subprocess.check_output(
        [pandoc, "--from=gfm", "--to=html5", "--wrap=none", str(root / source)],
        text=True,
    )

    def rewrite_link(match):
        url = urlsplit(html.unescape(match[1]))
        if url.scheme or url.netloc or not url.path:
            return match[0]
        target = (root / source).parent.joinpath(url.path).resolve().relative_to(root).as_posix()
        destination = pages[target][0] if target in pages else (
            "license.html" if target == "LICENSE" else
            "https://github.com/micksmix/everywhere/blob/main/" + target
        )
        return 'href="' + html.escape(urlunsplit(("", "", destination, url.query, url.fragment)), quote=True) + '"'

    body = re.sub(r'href="([^"]+)"', rewrite_link, body)
    (resources / name).write_text(document(title, body))

license_text = html.escape((root / "LICENSE").read_text())
(resources / "license.html").write_text(document(
    "Apache License 2.0",
    '<h1>Apache License 2.0</h1><p>Everywhere is licensed under the Apache License, Version 2.0. '
    '<a href="https://github.com/micksmix/everywhere">Everywhere on GitHub</a></p>'
    f'<pre>{license_text}</pre>',
))
digest = hashlib.sha256("".join(
    path.read_text() for path in sorted(resources.glob("*.html"))
).encode() + stylesheet.encode()).hexdigest()
version_number = 10_000_000 + int(digest[:12], 16) % 90_000_000
version = f"{version_number // 10000}.{version_number // 100 % 100}.{version_number % 100}"
metadata = {
    "CFBundleDevelopmentRegion": "en",
    "CFBundleIdentifier": "app.everywhere.macos.help",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleName": "Everywhere Help",
    "CFBundlePackageType": "BNDL",
    "CFBundleSignature": "hbwr",
    "CFBundleShortVersionString": "1.0",
    "CFBundleVersion": version,
    "HPDBookAccessPath": "index.html",
    "HPDBookIndexPath": "Everywhere.helpindex",
    "HPDBookTitle": "Everywhere Help",
    "HPDBookType": "3",
}
with (output / "Contents/Info.plist").open("wb") as stream:
    plistlib.dump(metadata, stream)
(resources / "InfoPlist.strings").write_text('"HPDBookTitle" = "Everywhere Help";\n')
subprocess.run([
    "/usr/bin/hiutil", "-I", "lsm", "-Caf", str(resources / "Everywhere.helpindex"),
    "-s", "en", "-l", "en", str(resources),
], check=True)
print(f"Built {output}")
