import ARKit
import MultipeerConnectivity
import Vision

/// Snaps a peer's tag onto the person holding the phone while they're in view.
///
/// Vision finds people in the camera image; each is turned into a ray from where the camera was when
/// the image was taken. A peer is matched to the person whose ray passes closest to where tracking
/// predicts them, provided their apparent size fits the distance and no other person is about as close
/// a match. The result is an offset (person − prediction) that the view adds to the tracked position,
/// so the tag sits on the person yet still moves every frame with tracking and the camera.
/// Each match is also a sub-degree bearing, which the tracker feeds into the alignment.
final class PersonSnapper {
    struct Target {
        var ours: SIMD3<Float>     // where tracking puts the peer (our world)
        var theirs: SIMD3<Float>?  // the same moment in their world, when fused
    }

    struct Snap {
        var point: SIMD3<Float>    // on the matched person (our world), at capture
        var offset: SIMD3<Float>   // eased point − prediction
        var time: TimeInterval     // capture time
    }

    /// Main queue, once per matched peer per detection.
    var onMatch: ((MCPeerID, Snap, Target) -> Void)?
    private(set) var snaps: [MCPeerID: Snap] = [:]

    private let queue = DispatchQueue(label: "uwbhud.people", qos: .userInitiated)
    private let request: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = true   // the phone is held in front of the upper body; also works up close
        return r
    }()
    private var busy = false
    private var frameCount = 0
    private var lockedYaw: [MCPeerID: Float] = [:]   // bearing of last match, to stay on the same person

    /// Upper body (head to waist) height in meters, for a rough distance from box size.
    private static let bodyHeight: Float = 0.8

    /// Call every AR frame. Runs detection on every other frame while the previous one isn't still running.
    func process(_ frame: ARFrame, targets: [MCPeerID: Target]) {
        frameCount += 1
        guard frameCount % 2 == 0, !busy, !targets.isEmpty, case .normal = frame.camera.trackingState else { return }
        busy = true
        let image = frame.capturedImage
        let camera = frame.camera.transform
        let intrinsics = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let time = CACurrentMediaTime()
        queue.async { [weak self] in
            guard let self else { return }
            // .right: the sensor image is landscape; Vision then reports boxes in portrait coordinates.
            try? VNImageRequestHandler(cvPixelBuffer: image, orientation: .right).perform([self.request])
            let boxes = (self.request.results ?? []).map(\.boundingBox)
            DispatchQueue.main.async {
                self.busy = false
                self.match(boxes, camera: camera, intrinsics: intrinsics, size: size, targets: targets, time: time)
            }
        }
    }

    func reset() {
        snaps.removeAll()
        lockedYaw.removeAll()
    }

    private func match(_ boxes: [CGRect], camera: simd_float4x4, intrinsics: simd_float3x3, size: CGSize,
                       targets: [MCPeerID: Target], time: TimeInterval) {
        let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
        let fx = intrinsics[0][0], fy = intrinsics[1][1], cx = intrinsics[2][0], cy = intrinsics[2][1]
        let w = Float(size.width), h = Float(size.height)
        // One world ray per person through the middle of their upper body, plus their height in pixels.
        // Vision's portrait box (origin bottom-left) maps back to the landscape sensor image as
        // x = (1 − midY)·width, y = (1 − midX)·height.
        let people: [(dir: SIMD3<Float>, pixels: Float)] = boxes.map { box in
            let x = (1 - Float(box.midY)) * w, y = (1 - Float(box.midX)) * h
            let ray = camera * SIMD4((x - cx) / fx, -(y - cy) / fy, -1, 0)   // camera space: y up, −z forward
            return (simd_normalize(SIMD3(ray.x, ray.y, ray.z)), Float(box.height) * w)
        }

        var claimed = Set<Int>()
        // Nearest peers first: they're the big, unambiguous people in view.
        for (peer, target) in targets.sorted(by: { simd_distance($0.value.ours, origin) < simd_distance($1.value.ours, origin) }) {
            let to = target.ours - origin
            let dist = simd_length(to)
            guard dist > 0.3 else { continue }
            let yaw = atan2(to.x, -to.z)
            let gate = max(12 * Float.pi / 180, atan(0.6 / dist))   // ±12°, wider up close
            var best: (index: Int, error: Float, yaw: Float)?
            var runnerUp = Float.infinity
            for (i, person) in people.enumerated() where !claimed.contains(i) && simd_dot(person.dir, to) > 0 {
                let sizeDistance = Self.bodyHeight * fx / max(person.pixels, 1)
                guard sizeDistance < dist * 2.2, dist < sizeDistance * 2.2 else { continue }
                let personYaw = atan2(person.dir.x, -person.dir.z)
                var error = abs(Self.angleBetween(personYaw, yaw))
                if let last = lockedYaw[peer], abs(Self.angleBetween(personYaw, last)) < 4 * Float.pi / 180 {
                    error *= 0.5   // same person as last time: keep them
                }
                guard error < gate else { continue }
                if let b = best, b.error <= error {
                    runnerUp = min(runnerUp, error)
                } else {
                    runnerUp = best?.error ?? runnerUp
                    best = (i, error, personYaw)
                }
            }
            // Two people about equally likely: don't guess.
            guard let best, runnerUp - best.error > 3 * Float.pi / 180 else {
                lockedYaw[peer] = nil
                continue
            }
            claimed.insert(best.index)
            lockedYaw[peer] = best.yaw
            let dir = people[best.index].dir
            let point = origin + dir * simd_dot(to, dir)   // on the ray, at the predicted distance
            var offset = point - target.ours
            if let old = snaps[peer], time - old.time < 0.3 {
                offset = old.offset + 0.35 * (offset - old.offset)   // box centers wobble a few cm frame to frame
            }
            let snap = Snap(point: point, offset: offset, time: time)
            snaps[peer] = snap
            onMatch?(peer, snap, target)
        }
    }

    private static func angleBetween(_ a: Float, _ b: Float) -> Float {
        let d = a - b
        return atan2(sin(d), cos(d))
    }
}
