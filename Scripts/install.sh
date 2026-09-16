#!/bin/sh
set -eu

REPO="micksmix/everywhere"

if [ "$(uname -s)" != "Darwin" ]; then
	echo "This installer is for macOS." >&2
	exit 1
fi

if [ "$(id -u)" = "0" ]; then
	echo "Do not run this installer as root; it installs to your /Applications." >&2
	exit 1
fi

echo "Fetching the latest Everywhere release…"
tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
if [ -z "$tag" ]; then
	echo "Could not determine the latest release from $REPO." >&2
	exit 1
fi
version="${tag#v}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/Everywhere.zip" \
	"https://github.com/$REPO/releases/download/$tag/Everywhere-$version.zip"
ditto -x -k "$work/Everywhere.zip" "$work/app"

rm -rf "/Applications/Everywhere.app"
ditto "$work/app/Everywhere.app" "/Applications/Everywhere.app"
xattr -dr com.apple.quarantine "/Applications/Everywhere.app" 2>/dev/null || true

echo "Installed Everywhere $version to /Applications."
echo "Launch it with: open /Applications/Everywhere.app"
