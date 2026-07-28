#!/usr/bin/env python3
"""Sorgt dafür, dass für die Sensorstorm-Bundle-ID ein App-Store-Provisioning-Profil
existiert, das das lokal vorhandene CI-Distribution-Zertifikat (siehe
`~/.appstoreconnect/ci-signing/`) enthält – und installiert es lokal unter
`~/Library/MobileDevice/Provisioning Profiles/`.

Grund (wie bei aarestation-app): Xcodes eigene "iOS Team Store Provisioning
Profile: …" hängen an einem Zertifikat, dessen privater Schlüssel nur in Xcodes
lokalem Schlüsselbund liegt – für ein Skript ohne Xcode-Sitzung unerreichbar.
Das Profil hier ("Sensorstorm CI Distribution") ist eigenständig und stört die
Xcode-eigenen nicht.

Das Zertifikat wird mit aarestation geteilt: beide Projekte laufen unter Team
E3CQ6W7CY2, und Apple erlaubt nur wenige Distribution-Zertifikate. `publish_ios.sh`
legt nur eines an, wenn `~/.appstoreconnect/ci-signing/` noch leer ist.

Idempotent: läuft ein zweites Mal, ohne Duplikate zu erzeugen, solange das
Zertifikat gleich bleibt.

Aufruf: ASC_KEY_ID=... ASC_ISSUER_ID=... python3 Tools/ensure_profiles.py
"""
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from asc import request  # noqa: E402

CERT_PATH = os.path.expanduser("~/.appstoreconnect/ci-signing/dist.cer")
PROFILES_DIR = os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles")

BUNDLE_ID = "ch.sensorstorm.app"
PROFILE_NAME = "Sensorstorm CI Distribution"

# Sensorstorm ist ein einzelnes Bundle: keine Widget-Extension, keine App Group,
# kein iCloud-Container. Alles bleibt im App-Container des Geräts.
#
# (Bundle-ID, Profilname, Capabilities die beim Neuanlegen gesetzt werden).
# Die App-ID selbst wird nie automatisch angelegt.
TARGETS = [
    (BUNDLE_ID, PROFILE_NAME, None),
]


def certificate_id() -> str:
    """Zertifikat-ID über die Seriennummer im lokalen .cer finden – zuverlässiger als
    mitgeführte IDs, die beim nächsten Zertifikatswechsel veralten."""
    import subprocess
    serial_hex = subprocess.check_output(
        ["openssl", "x509", "-inform", "DER", "-in", CERT_PATH, "-noout", "-serial"]
    ).decode().strip().split("=")[1].upper()

    status, raw = request("GET", "/v1/certificates?filter[certificateType]=DISTRIBUTION&limit=50")
    if status >= 400:
        print(f"FEHLER beim Zertifikat-Lookup: {raw}", file=sys.stderr)
        sys.exit(1)
    for cert in json.loads(raw)["data"]:
        if cert["attributes"].get("serialNumber", "").upper() == serial_hex:
            return cert["id"]
    print("FEHLER: lokales Zertifikat nicht in ASC gefunden (Seriennummer stimmt mit keinem überein).", file=sys.stderr)
    sys.exit(1)


def bundle_resource_id(identifier: str, capabilities: list[str] | None = None) -> str:
    """ASC-Ressourcen-ID der Bundle-ID nachschlagen statt sie zu hinterlegen — sie
    steht nirgends im Projekt und wäre sonst eine stille Fehlerquelle.

    Mit `capabilities` wird eine fehlende Bundle-ID angelegt statt abzubrechen. Das
    ist nur für Nebenbundles wie die Widget-Extension gedacht, deren Berechtigungen
    vollständig aus dem Projekt ableitbar sind."""
    status, raw = request("GET", f"/v1/bundleIds?filter[identifier]={identifier}&limit=10")
    if status >= 400:
        print(f"FEHLER beim Bundle-ID-Lookup: {raw}", file=sys.stderr)
        sys.exit(1)
    for entry in json.loads(raw)["data"]:
        if entry["attributes"].get("identifier") == identifier:
            return entry["id"]

    if capabilities is None:
        print(
            f"FEHLER: Bundle-ID {identifier} existiert im Developer-Portal noch nicht. "
            "Dort einmalig anlegen (mit iCloud-Container, App-Group und Associated Domains), "
            "danach läuft dieses Skript durch.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"  Bundle-ID fehlt — wird angelegt: {identifier}")
    body = {
        "data": {
            "type": "bundleIds",
            "attributes": {
                "identifier": identifier,
                "name": identifier.replace(".", " ").title(),
                "platform": "IOS",
            },
        }
    }
    status, raw = request("POST", "/v1/bundleIds", body)
    if status >= 400:
        print(f"FEHLER beim Anlegen von {identifier}: {raw}", file=sys.stderr)
        sys.exit(1)
    bundle_asc_id = json.loads(raw)["data"]["id"]
    for capability in capabilities:
        enable_capability(bundle_asc_id, capability)
    return bundle_asc_id


def enable_capability(bundle_asc_id: str, capability: str):
    """Idempotent: ist die Capability schon aktiv, antwortet ASC mit einem Konflikt,
    was hier kein Fehler ist."""
    body = {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": capability},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_asc_id}}
            },
        }
    }
    status, raw = request("POST", "/v1/bundleIdCapabilities", body)
    if status >= 400 and "DUPLICATE" not in raw and "already" not in raw.lower():
        print(f"FEHLER beim Aktivieren von {capability}: {raw}", file=sys.stderr)
        sys.exit(1)
    print(f"  Capability aktiv: {capability}")


def existing_profile(bundle_asc_id: str, name: str, cert_id: str) -> str | None:
    """UUID eines bereits passenden (Name + Zertifikat) aktiven Profils, sonst None."""
    status, raw = request("GET", f"/v1/bundleIds/{bundle_asc_id}/profiles")
    if status >= 400:
        return None
    for profile in json.loads(raw)["data"]:
        if profile["attributes"].get("name") != name:
            continue
        if profile["attributes"].get("profileState") != "ACTIVE":
            continue
        status2, raw2 = request("GET", f"/v1/profiles/{profile['id']}/certificates")
        if status2 >= 400:
            continue
        cert_ids = {c["id"] for c in json.loads(raw2)["data"]}
        if cert_id in cert_ids:
            return profile["id"]
    return None


def purge_invalid_profiles(bundle_asc_id: str, name: str):
    """Ändert sich eine Capability der App-ID, entwertet Apple die zugehörigen
    Profile — der Name bleibt aber belegt, und ein Neuanlegen scheitert dann an
    „Multiple profiles found with the name". Darum die toten vorher wegräumen."""
    status, raw = request("GET", f"/v1/bundleIds/{bundle_asc_id}/profiles?limit=50")
    if status >= 400:
        return
    for profile in json.loads(raw)["data"]:
        attrs = profile["attributes"]
        if attrs.get("name") != name or attrs.get("profileState") == "ACTIVE":
            continue
        del_status, _ = request("DELETE", f"/v1/profiles/{profile['id']}")
        state = attrs.get("profileState")
        if del_status < 400:
            print(f"  {state}es Profil entfernt: {profile['id']}")
        else:
            print(f"  WARNUNG: {state}es Profil {profile['id']} liess sich nicht entfernen")


def install_profile(profile_id: str):
    status, raw = request("GET", f"/v1/profiles/{profile_id}")
    if status >= 400:
        print(f"FEHLER beim Profil-Download: {raw}", file=sys.stderr)
        sys.exit(1)
    attrs = json.loads(raw)["data"]["attributes"]
    content = base64.b64decode(attrs["profileContent"])
    uuid = attrs["uuid"]
    os.makedirs(PROFILES_DIR, exist_ok=True)
    dest = os.path.join(PROFILES_DIR, f"{uuid}.mobileprovision")
    with open(dest, "wb") as f:
        f.write(content)
    print(f"  installiert: {dest}")


def create_profile(name: str, bundle_asc_id: str, cert_id: str) -> str:
    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_STORE"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_asc_id}},
                "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
            },
        }
    }
    status, raw = request("POST", "/v1/profiles", body)
    if status >= 400:
        print(f"FEHLER beim Profil-Erstellen ({name}): {raw}", file=sys.stderr)
        sys.exit(1)
    return json.loads(raw)["data"]["id"]


def main():
    cert_id = certificate_id()
    print(f"Verwende Zertifikat {cert_id}")

    for identifier, profile_name, capabilities in TARGETS:
        bundle_asc_id = bundle_resource_id(identifier, capabilities)
        print(f"==> {identifier} ({bundle_asc_id})")
        pid = existing_profile(bundle_asc_id, profile_name, cert_id)
        if pid:
            print(f"  bereits vorhanden & passend: {pid}")
        else:
            purge_invalid_profiles(bundle_asc_id, profile_name)
            pid = create_profile(profile_name, bundle_asc_id, cert_id)
            print(f"  neu erstellt: {pid}")
        install_profile(pid)

    print("\nProfile bereit.")


if __name__ == "__main__":
    main()
