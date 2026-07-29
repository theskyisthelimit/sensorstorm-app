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
import mathutils
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
    """Index of the video frame this pose belongs to, counted from the movie's first frame."""
    location: tuple[float, float, float]
    quaternion: tuple[float, float, float, float]  # w, x, y, z
    lens: float
    shift_x: float
    shift_y: float
    tracking_state: int


class VideoTiming(NamedTuple):
    """What is needed to say which video frame a pose belongs to.

    Poses and video frames are two streams that start and stop a few frames apart — the
    camera is armed before the pose writer and keeps delivering while the movie is being
    finalised. Matching them by row number therefore slides the whole animation against the
    background footage, so they are matched by time instead.
    """

    start_offset: float
    """Seconds from the recording start to the movie's first frame. Usually negative."""
    frame_rate: float

    @classmethod
    def from_manifest(cls, manifest: dict[str, Any]) -> "VideoTiming | None":
        video = manifest.get("video") or {}
        rate = float(video.get("nominalFrameRate") or 0)
        if rate <= 0:
            return None
        return cls(float(video.get("startOffsetSeconds") or 0), rate)

    def frame_index(self, seconds_elapsed: float) -> int:
        return round((seconds_elapsed - self.start_offset) * self.frame_rate)


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


def _read_frames(csv_path: str, crs: str, scale: float,
                 timing: VideoTiming | None = None,
                 frame_count: int | None = None) -> Iterator[Frame]:
    with open(csv_path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            index = _float(row, "frame_index")
            if index is None:
                continue

            if timing is not None:
                elapsed = _float(row, "seconds_elapsed")
                if elapsed is None:
                    continue
                index = timing.frame_index(elapsed)
                # A pose recorded before the movie opened or after it closed has no frame to
                # belong to. Keyframing it anyway would stretch the animation past the footage.
                if index < 0 or (frame_count is not None and index >= frame_count):
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

    import_terrain: BoolProperty(
        name="Import terrain",
        description="Build the swissALTI3D heightfield next to the bundle, if "
        "Tools/blender/fetch_swissalti3d.py has been run for it",
        default=True,
    )

    project_video: BoolProperty(
        name="Project video onto terrain",
        description="Throw the footage onto the terrain from the camera's own pose, so the "
        "images lie on the ground instead of floating in front of it",
        default=True,
    )

    eye_height: FloatProperty(
        name="Height above ground",
        description="Lift the whole track so its first frame sits this far above the "
        "terrain. GPS altitude is far too coarse to place a camera vertically — the terrain "
        "is not — so the height is stated rather than measured. 0 disables the correction",
        default=1.5,
        min=0.0,
        soft_max=3.0,
        unit="LENGTH",
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

        timing = VideoTiming.from_manifest(manifest)
        movie = self._load_movie(folder, manifest)
        frame_count = movie.frame_duration if movie else None

        try:
            frames = list(_read_frames(csv_path, self.crs, self.scale, timing, frame_count))
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
        self._apply_scene_settings(context, manifest, frames, frame_count)

        terrain = None
        if self.import_terrain:
            terrain = self._make_terrain(context, folder, manifest, anchor)
            if terrain is not None and self.eye_height > 0:
                self._seat_on_terrain(context, camera, terrain, frames)

        if self.import_video and movie is not None:
            self._attach_video(camera, movie, manifest)

        if self.project_video and terrain is not None:
            self._project_onto(terrain, camera, folder, manifest, frame_count)

        self._warn_about_quality(manifest)
        unmatched = manifest.get("frames", {}).get("count", len(frames)) - len(frames)
        self.report(
            {"INFO"},
            f"Imported {len(frames)} frames"
            + (f", skipped {skipped} unreliable" if skipped else "")
            + (f", {unmatched} outside the movie" if unmatched > 0 else ""),
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

        # The camera's location is keyframed, so any later correction has to live on a parent
        # rather than on the camera itself. This empty is that handle — it also makes the
        # applied height correction visible in the outliner instead of baked into the curves.
        track = bpy.data.objects.new(f"{name} track", None)
        track.empty_display_type = "SPHERE"
        track.empty_display_size = 0.2
        track.parent = anchor
        context.collection.objects.link(track)

        camera = bpy.data.objects.new(f"{name} camera", data)
        camera.rotation_mode = "QUATERNION"
        camera.parent = track
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

    # -- Terrain

    def _make_terrain(self, context: bpy.types.Context, folder: str,
                      manifest: dict[str, Any], anchor: bpy.types.Object) -> Any:
        """The swissALTI3D heightfield as a mesh, in the scene's own metres.

        Vertical alignment is the part worth getting right. swissALTI3D is LN02 orthometric;
        the ENU column is ellipsoidal. Both are measured from the same anchor, though, and the
        geoid separation is constant over a few hundred metres — so subtracting the anchor's
        own LN02 height puts the terrain in either system without ever naming the separation.
        """
        grid_path = os.path.join(folder, "terrain.npz")
        meta_path = os.path.join(folder, "terrain.json")
        if not (os.path.exists(grid_path) and os.path.exists(meta_path)):
            return None

        try:
            import numpy as np
        except ImportError:  # pragma: no cover - Blender always ships numpy
            self.report({"WARNING"}, "numpy is unavailable; skipping terrain")
            return None

        with open(meta_path, encoding="utf-8") as handle:
            info = json.load(handle)
        heights = np.load(grid_path)["heights"]

        spacing = float(info["spacing"]) * self.scale
        east0 = (info["originEast"] - info["anchorEast"]) * self.scale
        north0 = (info["originNorth"] - info["anchorNorth"]) * self.scale
        base = float(info["anchorHeight"])

        rows, columns = heights.shape
        vertices = []
        index_of = np.full(heights.shape, -1, dtype=np.int64)
        for row in range(rows):
            for column in range(columns):
                height = heights[row, column]
                if not math.isfinite(height):
                    continue
                index_of[row, column] = len(vertices)
                vertices.append((east0 + column * spacing,
                                 north0 + row * spacing,
                                 (height - base) * self.scale))

        faces = []
        for row in range(rows - 1):
            for column in range(columns - 1):
                corners = (index_of[row, column], index_of[row, column + 1],
                           index_of[row + 1, column + 1], index_of[row + 1, column])
                # swissALTI3D has holes over water; a quad with a missing corner is one.
                if min(corners) >= 0:
                    faces.append(tuple(int(c) for c in corners))

        if not faces:
            self.report({"WARNING"}, "The terrain grid held no usable cells")
            return None

        mesh = bpy.data.meshes.new("swissALTI3D")
        mesh.from_pydata(vertices, [], faces)
        mesh.update()

        terrain = bpy.data.objects.new("Terrain (swissALTI3D)", mesh)
        terrain.parent = anchor
        context.collection.objects.link(terrain)

        terrain["source"] = info.get("source", "")
        terrain["crs"] = info.get("crs", "")
        terrain["height_reference"] = info.get("heightReference", "")
        return terrain

    def _seat_on_terrain(self, context: bpy.types.Context, camera: bpy.types.Object,
                         terrain: bpy.types.Object, frames: list[Frame]) -> None:
        """Lifts the rig so the first frame sits `eye_height` above the ground.

        Worth being blunt about why this is needed. ARKit measures height relative to wherever
        the session began, and the bundle turns that into an absolute height using the GPS
        anchor — whose vertical accuracy is tens of metres. The terrain, meanwhile, is good to
        centimetres. So the vertical placement that comes out of the data is the least
        trustworthy number in the scene, and it lands the camera exactly on the ground: both
        it and the terrain are measured from the same anchor, so the error cancels into zero
        height rather than into a plausible one.

        Snapping to the terrain and adding a stated eye height replaces an unmeasured number
        with an admitted assumption. The horizontal track and the orientation are untouched.
        """
        scene = context.scene
        scene.frame_set(frames[0].index + 1)
        origin = camera.matrix_world.translation.copy()

        depsgraph = context.evaluated_depsgraph_get()
        hit, location, *_ = scene.ray_cast(
            depsgraph, origin + mathutils.Vector((0, 0, 500)), mathutils.Vector((0, 0, -1)))
        if not hit:
            self.report({"WARNING"}, "The track does not start over the terrain; "
                                     "height left as recorded")
            return

        lift = (location.z + self.eye_height * self.scale) - origin.z
        camera.parent.location.z += lift
        camera.parent["height_correction"] = lift
        camera.parent["height_correction_note"] = (
            "GPS altitude cannot place a camera vertically; this offset seats the track on "
            "the terrain at a stated eye height instead")

        self.report({"INFO"},
                    f"Raised the track {lift:+.2f} m so it starts "
                    f"{self.eye_height:.2f} m above the terrain")

    # -- Camera projection

    def _project_onto(self, target: bpy.types.Object, camera: bpy.types.Object,
                      folder: str, manifest: dict[str, Any],
                      frame_count: int | None) -> None:
        """Projects the footage onto `target` from the camera, per frame.

        A UV Project modifier rather than a baked texture: the camera moves, so the correct
        projection is a different one every frame, and freezing it would only be right for
        the frame it was frozen on. Baking is the separate step for a permanent texture.

        The projection is a shadowless one — geometry does not occlude it, so anything behind
        a building gets the building's pixels too. That is inherent to camera projection and
        the reason a coarse terrain smears where the real scene had walls.
        """
        video = manifest.get("video") or {}
        file_name = video.get("fileName")
        if not file_name:
            return
        path = os.path.join(folder, file_name)
        if not os.path.exists(path):
            return

        width = int(video.get("width") or 1920)
        height = int(video.get("height") or 1080)

        uv_layer = "SensorstormProjection"
        if uv_layer not in target.data.uv_layers:
            target.data.uv_layers.new(name=uv_layer)

        modifier = target.modifiers.new("Sensorstorm projection", "UV_PROJECT")
        modifier.uv_layer = uv_layer
        modifier.projector_count = 1
        modifier.projectors[0].object = camera
        modifier.aspect_x = width
        modifier.aspect_y = height

        image = bpy.data.images.load(path)
        image.source = "MOVIE"

        material = bpy.data.materials.new("Sensorstorm projection")
        material.use_nodes = True
        tree = material.node_tree
        tree.nodes.clear()

        texture = tree.nodes.new("ShaderNodeTexImage")
        texture.image = image
        texture.extension = "CLIP"  # otherwise the frame tiles across the whole terrain
        texture.image_user.frame_duration = frame_count or 1
        texture.image_user.frame_start = 1
        texture.image_user.use_auto_refresh = True
        texture.location = (-400, 200)

        uv_node = tree.nodes.new("ShaderNodeUVMap")
        uv_node.uv_map = uv_layer
        uv_node.location = (-620, 200)

        # Emission, not Principled: the footage already carries the light that fell on the
        # street. Running it through a lit shader would darken it by whatever the scene's
        # lighting happens to be, which has nothing to do with the moment it was recorded —
        # and it means the projection is visible without adding any lights at all.
        emission = tree.nodes.new("ShaderNodeEmission")
        emission.location = (-120, 200)

        # Away from the projected footprint the texture is transparent, and a terrain that
        # glowed black everywhere else would hide its own shape.
        backdrop = tree.nodes.new("ShaderNodeBsdfDiffuse")
        backdrop.inputs["Color"].default_value = (0.35, 0.35, 0.35, 1)
        backdrop.location = (-120, 0)

        mix = tree.nodes.new("ShaderNodeMixShader")
        mix.location = (120, 120)

        output = tree.nodes.new("ShaderNodeOutputMaterial")
        output.location = (340, 120)

        links = tree.links
        links.new(uv_node.outputs["UV"], texture.inputs["Vector"])
        links.new(texture.outputs["Color"], emission.inputs["Color"])
        # `CLIP` makes alpha 0 outside the frame, so alpha is exactly the projection mask.
        links.new(texture.outputs["Alpha"], mix.inputs["Fac"])
        links.new(backdrop.outputs["BSDF"], mix.inputs[1])
        links.new(emission.outputs["Emission"], mix.inputs[2])
        links.new(mix.outputs["Shader"], output.inputs["Surface"])

        target.data.materials.append(material)

    def _apply_scene_settings(
        self, context: bpy.types.Context, manifest: dict[str, Any],
        frames: list[Frame], frame_count: int | None
    ) -> None:
        scene = context.scene
        # The movie always starts at Blender frame 1; the first pose may be several frames
        # in, and the range has to cover the footage rather than only the posed part.
        scene.frame_start = 1
        scene.frame_end = frame_count if frame_count else frames[-1].index + 1

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

    def _load_movie(self, folder: str, manifest: dict[str, Any]) -> Any:
        """Loads the movie early, because its frame count is what bounds the pose matching."""
        file_name = (manifest.get("video") or {}).get("fileName")
        if not file_name:
            return None

        path = os.path.join(folder, file_name)
        if not os.path.exists(path):
            self.report({"WARNING"}, f"{file_name} is not in the bundle; no background set")
            return None
        try:
            return bpy.data.movieclips.load(path)
        except RuntimeError as error:
            self.report({"WARNING"}, f"Could not open {file_name}: {error}")
            return None

    def _attach_video(
        self, camera: bpy.types.Object, movie: Any, manifest: dict[str, Any]
    ) -> None:
        video = manifest.get("video") or {}
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
