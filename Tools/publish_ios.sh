#!/bin/bash
# Sensorstorm – iOS Build signieren & zu App Store Connect hochladen.
#
# Gleiches Verfahren wie aarestation-app (Tools/publish_ios.sh dort): manuelles
# Signing statt Xcodes Cloud-Autosigning, weil letzteres ohne interaktive
# Xcode-Sitzung mit "Cloud signing permission error" abbricht. Das
# "Sensorstorm CI Distribution"-Profil (siehe Tools/ensure_profiles.py) lebt
# unabhängig von Xcodes eigenen Profilen.
#
# Das Distribution-Zertifikat unter ~/.appstoreconnect/ci-signing/ wird mit
# aarestation geteilt – gleiches Team (E3CQ6W7CY2), und Apple erlaubt nur wenige
# Distribution-Zertifikate. Ist dort schon eines, wird es wiederverwendet; nur
# beim allerersten Lauf auf einer Maschine entsteht ein neues. Der private
# Schlüssel landet nie dauerhaft im Login-Keychain, sondern pro Lauf in einem
# frischen Temp-Keychain.
#
# Aufruf: ASC_KEY_ID=... ASC_ISSUER_ID=... bash Tools/publish_ios.sh [archivePfad]
#   archivePfad: optional, Default build/Sensorstorm.xcarchive
set -euo pipefail

# Repo-Wurzel aus dem Skriptpfad ableiten, damit der Lauf nicht an einem
# bestimmten Checkout-Ort klebt.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_ID="${ASC_KEY_ID:?ASC_KEY_ID fehlt}"
ISSUER="${ASC_ISSUER_ID:?ASC_ISSUER_ID fehlt}"
P8="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
ARCHIVE_PATH="${1:-build/Sensorstorm.xcarchive}"
SIGNING="$HOME/.appstoreconnect/ci-signing"
mkdir -p "$SIGNING"
cd "$ROOT"

[ -f "$P8" ] || { echo "FEHLER: API-Key fehlt: $P8" >&2; exit 1; }
[ -d "$ARCHIVE_PATH" ] || { echo "FEHLER: Archiv fehlt: $ARCHIVE_PATH (zuerst archivieren, siehe RELEASE.md)" >&2; exit 1; }

echo "==> 1/6  Distribution-Zertifikat (wiederverwendet falls vorhanden)"
if [ -f "$SIGNING/dist.key" ] && [ -f "$SIGNING/dist.cer" ]; then
  echo "  vorhandenes CI-Zertifikat wiederverwendet: $SIGNING/dist.cer"
else
  openssl genrsa -out "$SIGNING/dist.key" 2048
  openssl req -new -key "$SIGNING/dist.key" -out "$SIGNING/dist.csr" \
    -subj "/CN=Sensorstorm CI Distribution/O=Sensorstorm/C=CH"
  python3 - "$SIGNING/dist.csr" "$SIGNING/dist.cer" <<'PY'
import json, sys, base64
sys.path.insert(0, "Tools")
from asc import request
csr = open(sys.argv[1]).read()
body = {"data":{"type":"certificates","attributes":{
        "certificateType":"DISTRIBUTION","csrContent":csr}}}
status, raw = request("POST", "/v1/certificates", body)
d = json.loads(raw)
if status >= 400:
    print("FEHLER:", json.dumps(d, indent=2)); sys.exit(1)
a = d["data"]["attributes"]
open(sys.argv[2],"wb").write(base64.b64decode(a["certificateContent"]))
print("  erstellt:", a.get("certificateType"), "| gültig bis", a.get("expirationDate"))
PY
fi
openssl x509 -inform DER -in "$SIGNING/dist.cer" -out "$SIGNING/dist.pem"
P12PASS="hs$RANDOM$RANDOM"
openssl pkcs12 -export -inkey "$SIGNING/dist.key" -in "$SIGNING/dist.pem" \
  -out "$SIGNING/dist.p12" -passout pass:"$P12PASS" -name "Apple Distribution: Sensorstorm CI"
chmod 600 "$SIGNING/dist.key" "$SIGNING/dist.p12"

echo "==> 2/6  Provisioning-Profil sicherstellen"
python3 Tools/ensure_profiles.py

echo "==> 3/6  Temporären Keychain einrichten"
KCPASS="kc$RANDOM$RANDOM"
KC="/tmp/sensorstorm-build.keychain-db"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$KCPASS" "$KC"
security import "$SIGNING/dist.p12" -k "$KC" -P "$P12PASS" \
  -T /usr/bin/codesign -T /usr/bin/xcodebuild
OLD=$(security list-keychains -d user | sed -e 's/[" ]//g' | tr '\n' ' ')
security list-keychains -d user -s "$KC" $OLD
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KCPASS" "$KC" >/dev/null

cleanup() {
  echo "==> Aufräumen: Temp-Keychain entfernen"
  security list-keychains -d user -s $OLD || true
  security delete-keychain "$KC" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> 4/6  IPA exportieren (manuelles Signing, kein Cloud-Autosigning nötig)"
rm -rf build/export
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
  -exportPath build/export -exportOptionsPlist ExportOptions-CI.plist

echo "==> 5/6  Validieren"
IPA=$(ls build/export/*.ipa | head -1)
xcrun altool --validate-app -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

echo "==> 6/6  Hochladen"
xcrun altool --upload-app   -f "$IPA" -t ios --apiKey "$KEY_ID" --apiIssuer "$ISSUER"

echo
echo "FERTIG. Build hochgeladen. Processing dauert ~10–30 Min."
echo "Danach erscheint er in TestFlight; interne Tester können sofort testen."
