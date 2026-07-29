import ARKit
import SceneKit
import SwiftUI

/// Live preview for the ARKit capture path.
///
/// `AVCaptureVideoPreviewLayer` needs a capture session, and ARKit does not have one — it
/// owns the camera itself. `ARSCNView` is the cheapest thing that renders an existing
/// `ARSession`'s camera feed; with no scene attached it draws the background and nothing else.
struct ARPreviewView: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.backgroundColor = .black
        // Nothing is placed in this scene, so everything below the camera background is
        // pure overhead on a device that is busy doing odometry.
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = false
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session {
            view.session = session
        }
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) {
        // The session outlives the view and is paused by `SensorHub`; only stop rendering.
        view.isPlaying = false
    }
}
