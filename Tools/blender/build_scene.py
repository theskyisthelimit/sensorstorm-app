"""Build a .blend from a Sensorstorm scene bundle, headless.

    blender --background --python Tools/blender/build_scene.py -- <bundle-dir> <out.blend> [crs]

Runs the same add-on the UI uses, so what comes out of this is what an interactive import
would produce. Exists because the interesting failure — a camera that points somewhere
plausible but wrong — is only visible in a render, and a render needs a file.
"""

import os
import sys

import bpy


def main() -> int:
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    if len(argv) < 2:
        print(__doc__)
        return 2

    bundle, output = argv[0], argv[1]
    crs = argv[2] if len(argv) > 2 else "ENU"

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import sensorstorm_import

    sensorstorm_import.register()

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.unit_settings.system = "METRIC"

    result = bpy.ops.import_scene.sensorstorm(
        filepath=os.path.join(bundle, "scene.json"),
        crs=crs,
        import_video=True,
    )
    if "FINISHED" not in result:
        print(f"IMPORT FAILED: {result}")
        return 1

    camera = bpy.context.scene.camera
    if camera is None:
        print("IMPORT FAILED: no camera in the scene")
        return 1

    # A ground plane at the anchor's height, so a render shows whether the horizon sits
    # where the recording says it does. Not part of the import — this is scaffolding.
    bpy.ops.mesh.primitive_plane_add(size=200, location=(0, 0, 0))
    ground = bpy.context.active_object
    ground.name = "Ground (scaffolding)"

    _report(camera)

    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(output))
    print(f"WROTE {output}")
    return 0


def _report(camera: bpy.types.Object) -> None:
    """Prints what a human would otherwise have to open the file to check."""
    scene = bpy.context.scene
    print("\n--- scene ---")
    print(f"frames        {scene.frame_start}..{scene.frame_end} @ "
          f"{scene.render.fps / scene.render.fps_base:.3f} fps")
    print(f"resolution    {scene.render.resolution_x}x{scene.render.resolution_y}")

    keyframes = 0
    if camera.animation_data and camera.animation_data.action:
        for layer in camera.animation_data.action.layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    keyframes = max(keyframes,
                                    max((len(fc.keyframe_points) for fc in bag.fcurves),
                                        default=0))
    print(f"keyframes     {keyframes} per channel")

    first, last = scene.frame_start, scene.frame_end
    for frame in (first, (first + last) // 2, last):
        scene.frame_set(frame)
        location = camera.matrix_world.translation
        forward = camera.matrix_world.to_quaternion() @ __import__("mathutils").Vector((0, 0, -1))
        bearing = (90 - __import__("math").degrees(__import__("math").atan2(forward.y, forward.x))) % 360
        print(f"  frame {frame:>4}  pos ({location.x:7.2f},{location.y:7.2f},{location.z:7.2f}) m"
              f"   looking {bearing:5.1f}deg   lens {camera.data.lens:.1f} mm")

    parent = camera.parent
    if parent:
        print(f"anchor        {parent.get('latitude', 0):.6f}, {parent.get('longitude', 0):.6f}"
              f"   crs {parent.get('sensorstorm_crs', '?')}")


if __name__ == "__main__":
    sys.exit(main())
