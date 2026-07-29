#!/usr/bin/env python3
"""Check that the Blender importer reads what the Swift exporter writes.

The two halves of this pipeline are in different languages and neither compiler can see the
other, so the column order in `frames.csv` and the key names in `scene.json` are a contract
held together by nothing but agreement. This runs the importer's own parsing over a bundle
the Swift tests produced, which is the only place that contract can actually be tested.

    SS_BUNDLE_OUT=/tmp/ss-bundle swift test --filter bundleContents
    python3 Tools/blender/check_bundle.py /tmp/ss-bundle
"""

from __future__ import annotations

import importlib.util
import json
import math
import os
import sys
import types


def _load_importer(root: str) -> types.ModuleType:
    """Import the add-on with `bpy` stubbed out.

    Only the parsing helpers are exercised here; everything that touches Blender's data model
    needs Blender itself. The stub exists so the module-level imports resolve.
    """
    # Distinct classes, not `object` twice: the operator inherits from both and Python
    # rejects a duplicate base.
    class _Operator:
        pass

    class _ImportHelper:
        pass

    bpy = types.ModuleType("bpy")
    bpy.types = types.SimpleNamespace(Operator=_Operator, Context=object)
    bpy.props = types.SimpleNamespace(StringProperty=lambda **_: None)
    bpy.utils = types.SimpleNamespace()

    props = types.ModuleType("bpy.props")
    for name in ("BoolProperty", "EnumProperty", "FloatProperty", "StringProperty"):
        setattr(props, name, lambda **_: None)

    io_utils = types.ModuleType("bpy_extras.io_utils")
    io_utils.ImportHelper = _ImportHelper
    bpy_extras = types.ModuleType("bpy_extras")
    bpy_extras.io_utils = io_utils

    # Blender's vector maths, only imported at module level here — the parsing this script
    # exercises never touches it.
    mathutils = types.ModuleType("mathutils")
    mathutils.Vector = tuple

    sys.modules.update({
        "bpy": bpy,
        "bpy.props": props,
        "bpy_extras": bpy_extras,
        "bpy_extras.io_utils": io_utils,
        "mathutils": mathutils,
    })

    path = os.path.join(root, "sensorstorm_import.py")
    spec = importlib.util.spec_from_file_location("sensorstorm_import", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(bundle: str) -> int:
    module = _load_importer(os.path.dirname(os.path.abspath(__file__)))
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    with open(os.path.join(bundle, "scene.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)

    csv_path = os.path.join(bundle, "frames.csv")

    # Every key the importer reaches for has to exist, or it silently falls back to a default
    # and the scene ends up somewhere plausible but wrong.
    check(manifest.get("format") == "sensorstorm-scene", "scene.json is not a scene bundle")
    for section in ("recording", "coordinateSystem", "frames", "video", "anchor"):
        check(section in manifest, f"scene.json has no '{section}' section")
    for key in ("poseSource", "timingSource", "count"):
        check(key in manifest["frames"], f"frames section has no '{key}'")
    for key in ("nominalFrameRate", "width", "height", "fileName"):
        check(key in manifest["video"], f"video section has no '{key}'")
    for key in ("latitude", "longitude", "lv95East", "lv95North", "lv95Height",
                "altitudeEllipsoidal", "altitudeOrthometric"):
        check(key in manifest["anchor"], f"anchor has no '{key}'")

    for crs in ("ENU", "LV95", "ENU_ELLIPSOIDAL"):
        frames = list(module._read_frames(csv_path, crs, 1.0))
        check(bool(frames), f"{crs}: no frame parsed out of frames.csv")
        if not frames:
            continue

        check(len(frames) == manifest["frames"]["count"],
              f"{crs}: parsed {len(frames)} frames, manifest says {manifest['frames']['count']}")

        for frame in frames:
            check(all(math.isfinite(v) for v in frame.location),
                  f"{crs}: frame {frame.index} has a non-finite location")
            check(abs(sum(c * c for c in frame.quaternion) - 1) < 1e-6,
                  f"{crs}: frame {frame.index} quaternion is not unit length")
            check(5 < frame.lens < 200,
                  f"{crs}: frame {frame.index} lens {frame.lens:.1f} mm is not a phone camera")

        # LV95 is absolute metres; ENU is metres from the anchor. Confusing the two puts the
        # scene 2 600 km east of where it belongs, which is exactly what the rebasing in the
        # importer exists to prevent.
        magnitude = max(abs(frames[0].location[0]), abs(frames[0].location[1]))
        if crs == "LV95":
            check(magnitude > 1e6, "LV95 positions should be absolute Swiss coordinates")
        else:
            check(magnitude < 1e5, "ENU positions should be metres from the anchor")

    # The importer reorders xyzw into Blender's wxyz. A quaternion whose real part landed in
    # the wrong slot still normalises, so it has to be checked against the file directly.
    with open(csv_path, encoding="utf-8") as handle:
        header = handle.readline().strip().split(",")
        first = handle.readline().strip().split(",")
    row = dict(zip(header, first))
    parsed = next(module._read_frames(csv_path, "ENU", 1.0))
    check(abs(parsed.quaternion[0] - float(row["qw"])) < 1e-9,
          "quaternion was not reordered from xyzw to wxyz")
    check(abs(parsed.quaternion[1] - float(row["qx"])) < 1e-9,
          "quaternion x is in the wrong slot")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print(f"OK: {bundle} parses cleanly in all three coordinate systems")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
