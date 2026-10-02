import Foundation
import simd

/// Acceleration split into what points up and what points sideways, independent of how the
/// phone sits in its holder.
///
/// `userAcceleration` comes in the device frame. In a windscreen mount the phone is tilted by
/// whatever angle the mount happened to have, so "z" is not "up" and a threshold on z means
/// something different in every car. Gravity, delivered by the same `CMDeviceMotion` sample,
/// says where up is — projecting onto it gives a vertical component that means the same in
/// every mount, and the rest of the vector is the horizontal part.
public enum Kinematics {
    /// - Parameters:
    ///   - user: `CMDeviceMotion.userAcceleration`, in g, device frame.
    ///   - gravity: `CMDeviceMotion.gravity`, in g, device frame. Points towards the ground.
    /// - Returns: the vertical component, positive upwards, and the length of the horizontal
    ///   remainder — both in g. NaN when either input is not a finite vector.
    public static func verticalHorizontal(user: SIMD3<Double>,
                                          gravity: SIMD3<Double>) -> (vertical: Double, horizontal: Double) {
        let finite = [user.x, user.y, user.z, gravity.x, gravity.y, gravity.z].allSatisfy(\.isFinite)
        let length = simd_length(gravity)
        guard finite, length > 1e-6 else { return (.nan, .nan) }

        let down = gravity / length
        let along = simd_dot(user, down)
        let sideways = user - along * down
        // Gravity points down, so a push upwards has a negative component along it.
        return (-along, simd_length(sideways))
    }
}
