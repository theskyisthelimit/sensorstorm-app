"""Import a Sensorstorm scene bundle into Blender as an animated camera.

The bundle already speaks Blender's language: the exporter writes metres east/north/up with
Z up, and cameras that look down their own -Z with +Y up in the image. That is deliberate —
every reprojection bug in this domain comes from swizzling axes twice — so this importer
converts nothing. It reads numbers, reorders the quaternion (the CSV is xyzw, Blender wants
wxyz), and keyframes them.

The one thing it does decide is which height a metre-above-zero means, because that differs
per map source and is the difference between a scene that sits on the terrain and one that
floats fifty metres over it.
"""

from __future__ import annotations

import csv
import json
import math
import os
from typing import Any, Iterator, NamedTuple

import bpy
from bpy.props import BoolProperty, EnumProperty, FloatProperty
from bpy_extras.io_utils import ImportHelper


bl_info = {
    "name": "Sensorstorm Scene",
    "author": "Sensorstorm",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "File > Import > Sensorstorm Scene",
    "description": "Import camera poses and intrinsics recorded by Sensorstorm",
    "category": "Import-Export",
}

BLENDER_SENSOR_WIDTH = 36.0
"""Blender's default sensor width in millimetres. Only the ratio to `fx` matters, so any
consistent value works — but changing it silently changes every imported lens, so it is
pinned here rather than read from the camera."""

UNCERTAIN_YAW_DEGREES = 10.0
"""Above this the GPS fit found no real heading and the scene's rotation is a suggestion."""


class Frame(NamedTuple):
    index: int
    location: tuple[float, float, float]
    quaternion: tuple[float, float, float, float]  # w, x, y, z
    lens: float
    shift_x: float
    shift_y: float
    tracking_state: int


def _float(row: dict[str, str], key: str) -> float | None:
    """The exporter writes an empty field for anything non-finite, which is its way of
    saying "this frame has no position" rather than "this frame is at zero"."""
    text = row.get(key, "").strip()
    if not text:
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def _read_frames(csv_path: str, crs: str, scale: float) -> Iterator[Frame]:
    with open(csv_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            index = _float(row, "frame_index")
            if index is None:
                continue

            location = _location(row, crs)
            if location is None:
                continue

            quaternion = _quaternion(row)
            if quaternion is None:
                continue

            width = _float(row, "image_width")
            height = _float(row, "image_height")
            fx = _float(row, "fx")
            cx = _float(row, "cx")
            cy = _float(row, "cy")
            if not width or not height or not fx:
                continue

            larger = max(width, height)
            yield Frame(
                index=int(index),
                location=tuple(component * scale for component in location),
                quaternion=quaternion,
                lens=fx * BLENDER_SENSOR_WIDTH / width,
                # Blender normalises both shifts by the larger image dimension, and its
                # vertical axis points the opposite way to an image's.
                shift_x=((cx - width / 2) / larger) if cx is not None else 0.0,
                shift_y=((height / 2 - cy) / larger) if cy is not None else 0.0,
                tracking_state=int(_float(row, "tracking_state") or 0),
            )


def _location(row: dict[str, str], crs: str) -> tuple[float, float, float] | None:
    """Positions in the chosen coordinate reference system, relative to the bundle's anchor.

    LV95 is absolute in metres — around 2 600 000 east — so it is rebased onto the anchor
    rather than dropped into the scene as-is; Blender's single-precision viewport loses
    centimetres at those magnitudes.
    """
    if crs == "LV95":
        east = _float(row, "e_lv95")
        north = _float(row, "n_lv95")
        up = _float(row, "h_lv95")
    else:
        east = _float(row, "x_enu")
        north = _float(row, "y_enu")
        up = _float(row, "z_enu")

    if east is None or north is None or up is None:
        return None
    return (east, north, up)


def _quaternion(row: dict[str, str]) -> tuple[float, float, float, float] | None:
    parts = [_float(row, key) for key in ("qx", "qy", "qz", "qw")]
    if any(part is None for part in parts):
        return None
    x, y, z, w = parts  # type: ignore[misc]
    return (w, x, y, z)


def _lv95_origin(manifest: dict[str, Any]) -> tuple[float, float, float]:
    anchor = manifest.get("anchor") or {}
    return (
        float(anchor.get("lv95East", 0.0)),
        float(anchor.get("lv95North", 0.0)),
        float(anchor.get("lv95Height", 0.0)),
    )


class SENSORSTORM_OT_import_scene(bpy.types.Operator, ImportHelper):
    """Import a Sensorstorm scene bundle"""

    bl_idname = "import_scene.sensorstorm"
    bl_label = "Import Sensorstorm Scene"
    bl_options = {"REGISTER", "UNDO"}

    filename_ext = ".json"
    filter_glob: bpy.props.StringProperty(default="*.json", options={"HIDDEN"})

    crs: EnumProperty(
        name="Coordinate system",
        description="Which world the imported camera lives in",
        items=[
            (
                "ENU",
                "ENU (BlenderGIS / OSM)",
                "Metres east/north/up from the anchor. Height is ellipsoidal",
            ),
            (
                "LV95",
                "LV95 (swisstopo)",
                "Swiss EPSG:2056, rebased onto the anchor. Height is orthometric, "
                "which is what swissALTI3D terrain expects",
            ),
            (
                "ENU_ELLIPSOIDAL",
                "ENU, ellipsoidal (Google 3D Tiles)",
                "Same axes as ENU. Named separately because Blosm tiles are referenced "
                "to the ellipsoid, so this is the height to keep",
            ),
        ],
        default="ENU",
    )

    scale: FloatProperty(
        name="Scale",
        description="Metres per Blender unit",
        default=1.0,
        min=1e-6,
    )

    import_video: BoolProperty(
        name="Video as camera background",
        description="Show the recorded movie behind the camera, for checking the fit "
        "against the terrain",
        default=True,
    )

    skip_unreliable: BoolProperty(
        name="Skip unreliable frames",
        description="Leave out frames ARKit did not track normally, rather than "
        "keyframing a pose it did not trust",
        default=False,
    )

    def execute(self, context: bpy.types.Context) -> set[str]:
        folder = os.path.dirname(self.filepath)
        csv_path = os.path.join(folder, "frames.csv")

        if not os.path.exists(csv_path):
            self.report({"ERROR"}, "frames.csv is missing next to scene.json")
            return {"CANCELLED"}

        try:
            with open(self.filepath, encoding="utf-8") as handle:
                manifest = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            self.report({"ERROR"}, f"Could not read scene.json: {error}")
            return {"CANCELLED"}

        try:
            frames = list(_read_frames(csv_path, self.crs, self.scale))
        except (OSError, csv.Error) as error:
            self.report({"ERROR"}, f"Could not read frames.csv: {error}")
            return {"CANCELLED"}

        if not frames:
            self.report({"ERROR"}, "frames.csv holds no frame with a usable pose")
            return {"CANCELLED"}

        skipped = 0
        if self.skip_unreliable:
            kept = [frame for frame in frames if frame.tracking_state == 0]
            skipped = len(frames) - len(kept)
            frames = kept
            if not frames:
                self.report({"ERROR"}, "Every frame was tracked unreliably")
                return {"CANCELLED"}

        anchor = self._make_anchor(context, manifest)
        camera = self._make_camera(context, manifest, anchor, frames)
        self._apply_scene_settings(context, manifest, frames)

        if self.import_video:
            self._attach_video(camera, folder, manifest)

        self._warn_about_quality(manifest)
        self.report(
            {"INFO"},
            f"Imported {len(frames)} frames"
            + (f", skipped {skipped} unreliable" if skipped else ""),
        )
        return {"FINISHED"}

    # -- Scene construction

    def _make_anchor(
        self, context: bpy.types.Context, manifest: dict[str, Any]
    ) -> bpy.types.Object:
        """An Empty at the scene origin carrying the geodetic origin as custom properties, so
        the .blend documents where in the world it is without needing the bundle alongside."""
        recording = manifest.get("recording") or {}
        name = recording.get("name") or "Sensorstorm"

        empty = bpy.data.objects.new(f"{name} anchor", None)
        empty.empty_display_type = "PLAIN_AXES"
        context.collection.objects.link(empty)

        empty["sensorstorm_crs"] = self.crs
        empty["sensorstorm_recording_id"] = recording.get("id", "")
        empty["sensorstorm_capture_engine"] = recording.get("captureEngine", "")

        anchor = manifest.get("anchor")
        if anchor:
            empty["latitude"] = anchor.get("latitude", 0.0)
            empty["longitude"] = anchor.get("longitude", 0.0)
            empty["altitude_ellipsoidal"] = anchor.get("altitudeEllipsoidal", 0.0)
            empty["altitude_orthometric"] = anchor.get("altitudeOrthometric", 0.0)
            if self.crs == "LV95":
                east, north, up = _lv95_origin(manifest)
                empty["lv95_origin"] = (east, north, up)
        return empty

    def _make_camera(
        self,
        context: bpy.types.Context,
        manifest: dict[str, Any],
        anchor: bpy.types.Object,
        frames: list[Frame],
    ) -> bpy.types.Object:
        recording = manifest.get("recording") or {}
        name = recording.get("name") or "Sensorstorm"

        data = bpy.data.cameras.new(f"{name} camera")
        data.sensor_fit = "HORIZONTAL"
        data.sensor_width = BLENDER_SENSOR_WIDTH

        camera = bpy.data.objects.new(f"{name} camera", data)
        camera.rotation_mode = "QUATERNION"
        camera.parent = anchor
        context.collection.objects.link(camera)
        context.scene.camera = camera

        origin = _lv95_origin(manifest) if self.crs == "LV95" else (0.0, 0.0, 0.0)
        offset = tuple(component * self.scale for component in origin)

        for frame in frames:
            blender_frame = frame.index + 1  # Blender counts from one

            camera.location = (
                frame.location[0] - offset[0],
                frame.location[1] - offset[1],
                frame.location[2] - offset[2],
            )
            camera.rotation_quaternion = frame.quaternion
            camera.keyframe_insert("location", frame=blender_frame)
            camera.keyframe_insert("rotation_quaternion", frame=blender_frame)

            # Autofocus moves the focal length during a recording, so the intrinsics are
            # animated too rather than sampled once at the start.
            data.lens = frame.lens
            data.shift_x = frame.shift_x
            data.shift_y = frame.shift_y
            data.keyframe_insert("lens", frame=blender_frame)
            data.keyframe_insert("shift_x", frame=blender_frame)
            data.keyframe_insert("shift_y", frame=blender_frame)

        return camera

    def _apply_scene_settings(
        self, context: bpy.types.Context, manifest: dict[str, Any], frames: list[Frame]
    ) -> None:
        scene = context.scene
        scene.frame_start = frames[0].index + 1
        scene.frame_end = frames[-1].index + 1

        video = manifest.get("video") or {}
        rate = float(video.get("nominalFrameRate") or 0)
        if rate > 0:
            # Blender wants an integer fps with a base; 29.97 and friends need the base.
            scene.render.fps = max(int(round(rate)), 1)
            scene.render.fps_base = scene.render.fps / rate

        width = int(video.get("width") or 0)
        height = int(video.get("height") or 0)
        if width > 0 and height > 0:
            scene.render.resolution_x = width
            scene.render.resolution_y = height

    def _attach_video(
        self, camera: bpy.types.Object, folder: str, manifest: dict[str, Any]
    ) -> None:
        video = manifest.get("video") or {}
        file_name = video.get("fileName")
        if not file_name:
            return

        path = os.path.join(folder, file_name)
        if not os.path.exists(path):
            self.report({"WARNING"}, f"{file_name} is not in the bundle; no background set")
            return

        movie = bpy.data.movieclips.load(path)
        data = camera.data
        data.show_background_images = True
        background = data.background_images.new()
        background.source = "MOVIE_CLIP"
        background.clip = movie
        background.frame_method = "FIT"
        background.alpha = 0.5

        if not video.get("intrinsicsMatchStoredPixels", True):
            self.report(
                {"WARNING"},
                "The stored video was rotated after capture; the background will not line "
                "up with the intrinsics",
            )

    def _warn_about_quality(self, manifest: dict[str, Any]) -> None:
        frames = manifest.get("frames") or {}
        pose_source = frames.get("poseSource")
        if pose_source and pose_source != "arkitVIO":
            self.report(
                {"WARNING"},
                f"Pose source is '{pose_source}': this bundle has no camera orientation. "
                "Record in ARKit mode for frames you want placed in 3D",
            )

        timing = frames.get("timingSource")
        if timing == "nominalRate":
            self.report(
                {"WARNING"},
                "Frame times were reconstructed from the nominal rate and drift wherever "
                "the camera dropped a frame",
            )

        alignment = manifest.get("alignment") or {}
        uncertainty = alignment.get("yawUncertaintyDegrees")
        if uncertainty is not None and uncertainty > UNCERTAIN_YAW_DEGREES:
            self.report(
                {"WARNING"},
                f"The GPS heading fit is uncertain to ±{uncertainty:.0f}°. The scene's "
                "rotation about the vertical is a guess — a longer track fixes this",
            )


def menu_func_import(self, context: bpy.types.Context) -> None:
    self.layout.operator(
        SENSORSTORM_OT_import_scene.bl_idname, text="Sensorstorm Scene (scene.json)"
    )


def register() -> None:
    bpy.utils.register_class(SENSORSTORM_OT_import_scene)
    bpy.types.TOPBAR_MT_file_import.append(menu_func_import)


def unregister() -> None:
    bpy.types.TOPBAR_MT_file_import.remove(menu_func_import)
    bpy.utils.unregister_class(SENSORSTORM_OT_import_scene)


if __name__ == "__main__":
    register()
