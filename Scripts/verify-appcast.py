import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

feed, archive = map(pathlib.Path, sys.argv[1:])
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(feed).findall("./channel/item")
if len(items) != 1:
    raise SystemExit("Expected exactly one update in the release feed")
item = items[0]
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("Missing update enclosure")
with zipfile.ZipFile(archive) as bundle:
    info = plistlib.loads(bundle.read("Everywhere.app/Contents/Info.plist"))
version = info["CFBundleVersion"]
expected_url = f"https://github.com/micksmix/everywhere/releases/download/v{version}/{archive.name}"
if enclosure.get("url") != expected_url:
    raise SystemExit("Update URL does not match the release archive")
if enclosure.get("length") != str(archive.stat().st_size):
    raise SystemExit("Update length does not match the release archive")
if item.findtext(namespace + "version") != version:
    raise SystemExit("Update version does not match the bundle")
public_key = base64.b64decode(info["SUPublicEDKey"], validate=True)
signature = base64.b64decode(enclosure.attrib[namespace + "edSignature"], validate=True)
if len(public_key) != 32 or len(signature) != 64:
    raise SystemExit("Invalid update key or signature length")
with tempfile.TemporaryDirectory() as temporary:
    directory = pathlib.Path(temporary)
    (directory / "public-key").write_bytes(public_key)
    (directory / "signature").write_bytes(signature)
    (directory / "verify.swift").write_text('''import CryptoKit
import Foundation
let args = CommandLine.arguments
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[1])))
let signature = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the public key embedded in the app\\n", stderr)
    exit(1)
}
''')
    subprocess.run(["swift", str(directory / "verify.swift"), str(directory / "public-key"),
                    str(directory / "signature"), str(archive.resolve())], check=True)
print(f"Verified signed update for Everywhere {version}")
