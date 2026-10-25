import ARKit
import RealityKit
import UIKit

// Main-queue state; video frames remain entirely in the existing native publisher.
enum WaypointBridge {
    static var reference: [String: Any]?
    static var canPlace = false
    static var armed = false
    static var placementDistance: Float?
    static var onEvent: ((String, [String: Any]) -> Void)?
}

final class WaypointOverlay: NSObject {
    private weak var arView: ARView?
    private weak var tracker: UWBTracker?
    private let root = AnchorEntity(world: .zero)
    private let marker = ModelEntity(mesh: .generateBox(size: 0.09), materials: [UnlitMaterial(color: .systemOrange)])
    private let label = UILabel()
    private var gesture: UITapGestureRecognizer?
    private var lastStatus = ""
    private var statusUntil: TimeInterval = 0

    init(arView: ARView, tracker: UWBTracker, container: UIView) {
        self.arView = arView
        self.tracker = tracker
        super.init()
        marker.orientation = simd_quatf(angle: .pi / 4, axis: SIMD3(0, 0, 1))
        marker.isEnabled = false
        root.addChild(marker)
        arView.scene.addAnchor(root)
        label.bounds = CGRect(x: 0, y: 0, width: 210, height: 72)
        label.numberOfLines = 3
        label.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        label.textColor = .systemOrange
        label.textAlignment = .center
        label.backgroundColor = UIColor(white: 0.08, alpha: 0.9)
        label.layer.borderColor = UIColor.systemOrange.cgColor
        label.layer.borderWidth = 2
        label.layer.cornerRadius = 3
        label.isUserInteractionEnabled = false
        label.isHidden = true
        container.addSubview(label)
        let tap = UITapGestureRecognizer(target: self, action: #selector(place(_:)))
        tap.cancelsTouchesInView = false
        arView.addGestureRecognizer(tap)
        gesture = tap
    }

    func stop() {
        if let gesture { arView?.removeGestureRecognizer(gesture) }
        root.removeFromParent()
        label.removeFromSuperview()
        WaypointBridge.armed = false
    }

    private func status(_ text: String, hold: TimeInterval = 0) {
        let now = CACurrentMediaTime()
        if hold > 0 { statusUntil = now + hold }
        else if now < statusUntil { return }
        guard text != lastStatus else { return }
        lastStatus = text
        WaypointBridge.onEvent?("onWaypointStatus", ["message": text])
    }

    private func pick(_ screen: CGPoint, in view: ARView) -> (point: SIMD3<Float>, kind: String)? {
        guard let frame = view.session.currentFrame, let ray = view.ray(through: screen) else { return nil }
        if let distance = WaypointBridge.placementDistance {
            return (ray.origin + simd_normalize(ray.direction) * distance, "distance")
        }
        let offsets = [CGPoint.zero, CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: -10), CGPoint(x: 0, y: 10)]
        let targets: [ARRaycastQuery.Target] = [.existingPlaneGeometry, .estimatedPlane, .existingPlaneInfinite]
        for target in targets {
            for offset in offsets {
                let tap = CGPoint(x: screen.x + offset.x, y: screen.y + offset.y)
                for hit in view.raycast(from: tap, allowing: target, alignment: .any) {
                    let t = hit.worldTransform.columns.3
                    let point = SIMD3(t.x, t.y, t.z)
                    if (0.15...15).contains(simd_distance(point, ray.origin)) { return (point, "surface") }
                }
            }
        }
        // A visible feature is an estimated point, not a claimed plane intersection.
        var best: (point: SIMD3<Float>, score: CGFloat)?
        for point in frame.rawFeaturePoints?.points ?? [] {
            let distance = simd_distance(point, ray.origin)
            guard (0.15...12).contains(distance), simd_dot(point - ray.origin, ray.direction) > 0,
                  let projected = view.project(point) else { continue }
            let pixels = hypot(projected.x - screen.x, projected.y - screen.y)
            guard pixels <= 18 else { continue }
            let score = pixels + CGFloat(distance) * 0.05
            if best == nil || score < best!.score { best = (point, score) }
        }
        return best.map { ($0.point, "feature") }
    }

    @objc private func place(_ tap: UITapGestureRecognizer) {
        guard WaypointBridge.canPlace, WaypointBridge.armed, let arView, let tracker else { return }
        guard let result = pick(tap.location(in: arView), in: arView) else {
            status("No surface found. Scan from another angle, or select Distance placement.", hold: 4)
            return
        }
        guard let reference = tracker.waypointReference(result.point) else {
            status("AR tracking is not ready. Move slowly and try again.", hold: 4)
            return
        }
        WaypointBridge.armed = false
        WaypointBridge.onEvent?("onWaypointTap", ["reference": reference, "placement": result.kind])
        status(result.kind == "surface" ? "Sending waypoint…" : "Sending estimated waypoint…", hold: 2)
    }

    /// Only touches the marker and label when something changes: this runs every frame.
    private func show(marker visible: Bool) {
        if marker.isEnabled != visible { marker.isEnabled = visible }
        if !visible, !label.isHidden { label.isHidden = true }
    }

    func tick(camera: ARCamera) {
        guard let arView, let tracker, let reference = WaypointBridge.reference else {
            show(marker: false)
            if WaypointBridge.armed {
                status(WaypointBridge.placementDistance == nil ? "Tap a visible surface to place the waypoint." : "Tap a direction for the estimated distance placement.")
            }
            return
        }
        guard let peer = reference["peer"] as? String,
              let epoch = reference["epoch"] as? NSNumber,
              let xyz = reference["position"] as? [Double], xyz.count == 3,
              let p = tracker.mapWaypoint(SIMD3(Float(xyz[0]), Float(xyz[1]), Float(xyz[2])),
                                          from: peer, epoch: epoch.uint32Value, at: CACurrentMediaTime()) else {
            show(marker: false)
            status("Waypoint shared. Waiting for peer AR alignment or valid tracking.")
            return
        }
        marker.position = p
        show(marker: true)
        let t = camera.transform.columns.3
        let distance = simd_distance(p, SIMD3(t.x, t.y, t.z))
        let cam = camera.viewMatrix(for: .portrait) * SIMD4(p, 1)
        let projected = arView.project(p)
        let name = String((reference["name"] as? String ?? "Waypoint").prefix(40))
        let kind = reference["placement"] as? String ?? "surface"
        let suffix = kind == "surface" ? "" : kind == "distance" ? " · distance" : " · estimated"
        let inside = cam.z < 0 && projected.map { arView.bounds.insetBy(dx: 100, dy: 130).contains($0) } == true
        let text: String
        if inside, let projected {
            label.center = CGPoint(x: projected.x, y: projected.y - 48)
            text = String(format: "◆ WAYPOINT\n%@\n%.1f m%@", name, distance, suffix)
        } else {
            label.center = CGPoint(x: arView.bounds.midX, y: 160)
            text = String(format: "◆ WAYPOINT · OFF SCREEN\n%@\n%.1f m%@", name, distance, suffix)
        }
        if label.text != text { label.text = text }   // the distance is rounded, so this mostly holds still
        if label.isHidden { label.isHidden = false }
        // Peer tags share this layer and can be added later; keep the label above them without re-sorting every frame.
        if let superview = label.superview, superview.subviews.last !== label { superview.bringSubviewToFront(label) }
        status(WaypointBridge.armed ? "Tap a surface to replace the waypoint." : "Shared waypoint active.")
    }
}
