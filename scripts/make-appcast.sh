#!/bin/zsh
set -euo pipefail

signer="${1:?Provide the path to Sparkle sign_update}"
archive="${2:?Provide the universal ZIP}"
download_url="${3:?Provide the ZIP download URL}"
appcast="${4:?Provide the appcast output path}"
notes="${5:-}"
: "${CODEXRING_SPARKLE_PRIVATE_KEY:?Configure the Sparkle release signing key}"

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
plist="$workspace/Info.plist"
unzip -p "$archive" CodexRing.app/Contents/Info.plist > "$plist"
public_key=$(plutil -extract SUPublicEDKey raw "$plist")
build_number=$(plutil -extract CFBundleVersion raw "$plist")
version=$(plutil -extract CFBundleShortVersionString raw "$plist")
minimum_system=$(plutil -extract LSMinimumSystemVersion raw "$plist")
signature=$(printf '%s\n' "$CODEXRING_SPARKLE_PRIVATE_KEY" | "$signer" --ed-key-file - -p "$archive")

# Verify against the public key in the actual bundle, not against CI settings.
swift - "$archive" "$public_key" "$signature" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .mappedIfSafe)
guard let publicKey = Data(base64Encoded: arguments[2]),
      let signature = Data(base64Encoded: arguments[3]),
      try Curve25519.Signing.PublicKey(rawRepresentation: publicKey).isValidSignature(signature, for: archive) else {
    fputs("Update signature does not match the bundled public key.\n", stderr)
    exit(1)
}
SWIFT

python3 - "$workspace/appcast.xml" "$archive" "$download_url" "$version" "$build_number" "$minimum_system" "$signature" "$notes" <<'PYTHON'
from email.utils import formatdate
from html import escape
from pathlib import Path
import sys
from xml.etree import ElementTree as ET

output, archive, url, version, build, minimum, signature, notes = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", sparkle)
rss = ET.Element("rss", version="2.0")
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "CodexRing"
item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"CodexRing {version}"
ET.SubElement(item, "pubDate").text = formatdate(usegmt=True)
ET.SubElement(item, f"{{{sparkle}}}version").text = build
ET.SubElement(item, f"{{{sparkle}}}shortVersionString").text = version
ET.SubElement(item, f"{{{sparkle}}}minimumSystemVersion").text = minimum
if notes:
    ET.SubElement(item, "description").text = f"<pre>{escape(Path(notes).read_text())}</pre>"
ET.SubElement(item, "enclosure", {
    "url": url,
    "length": str(Path(archive).stat().st_size),
    "type": "application/octet-stream",
    f"{{{sparkle}}}edSignature": signature,
})
ET.indent(rss)
ET.ElementTree(rss).write(output, encoding="utf-8", xml_declaration=True)
PYTHON

printf '%s\n' "$CODEXRING_SPARKLE_PRIVATE_KEY" | "$signer" --ed-key-file - "$workspace/appcast.xml"
mv "$workspace/appcast.xml" "$appcast"
