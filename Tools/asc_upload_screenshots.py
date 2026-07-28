#!/usr/bin/env python3
"""Upload screenshots to an appStoreVersionLocalization via the reserve/PUT/commit flow.

Usage:
  asc_upload_screenshots.py <localizationId> <displayType> <img1> <img2> ...
Example:
  asc_upload_screenshots.py 5ac40df9-... APP_IPHONE_67 /tmp/shots/1-dashboard.png ...
"""
import hashlib
import json
import os
import sys
import urllib.request

# reuse token() + request() + _SSL_CTX from asc.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc import request, _SSL_CTX  # noqa: E402


def create_set(localization_id, display_type):
    # find-or-create: reuse an existing set of this display type if present
    status, raw = request(
        "GET",
        f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets")
    if status < 400:
        for s in json.loads(raw).get("data", []):
            if s["attributes"]["screenshotDisplayType"] == display_type:
                return s["id"]
    body = {"data": {
        "type": "appScreenshotSets",
        "attributes": {"screenshotDisplayType": display_type},
        "relationships": {"appStoreVersionLocalization": {
            "data": {"type": "appStoreVersionLocalizations", "id": localization_id}}},
    }}
    status, raw = request("POST", "/v1/appScreenshotSets", body)
    if status >= 400:
        raise SystemExit(f"create_set failed {status}: {raw}")
    return json.loads(raw)["data"]["id"]


def reserve(set_id, file_path):
    size = os.path.getsize(file_path)
    body = {"data": {
        "type": "appScreenshots",
        "attributes": {"fileSize": size, "fileName": os.path.basename(file_path)},
        "relationships": {"appScreenshotSet": {
            "data": {"type": "appScreenshotSets", "id": set_id}}},
    }}
    status, raw = request("POST", "/v1/appScreenshots", body)
    if status >= 400:
        raise SystemExit(f"reserve failed {status}: {raw}")
    return json.loads(raw)["data"]


def upload_bytes(ops, data):
    for op in ops:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"])
        for h in op.get("requestHeaders", []):
            req.add_header(h["name"], h["value"])
        with urllib.request.urlopen(req, context=_SSL_CTX) as resp:
            if resp.status >= 400:
                raise SystemExit(f"PUT failed {resp.status}")


def commit(shot_id, checksum):
    body = {"data": {"type": "appScreenshots", "id": shot_id,
                     "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}}
    status, raw = request("PATCH", f"/v1/appScreenshots/{shot_id}", body)
    if status >= 400:
        raise SystemExit(f"commit failed {status}: {raw}")


def main():
    localization_id = sys.argv[1]
    display_type = sys.argv[2]
    files = sys.argv[3:]
    set_id = create_set(localization_id, display_type)
    print(f"set {set_id} ({display_type})")
    for fp in files:
        with open(fp, "rb") as f:
            data = f.read()
        shot = reserve(set_id, fp)
        upload_bytes(shot["attributes"]["uploadOperations"], data)
        commit(shot["id"], hashlib.md5(data).hexdigest())
        print(f"  uploaded {os.path.basename(fp)} -> {shot['id']}")
    print("done")


if __name__ == "__main__":
    main()
