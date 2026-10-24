import ARKit
import Combine
import ExpoModulesCore
import MultipeerConnectivity
import RealityKit

/// Native camera view for React Native.
///   Native side: camera, UWB ranging, 3D marker dots (smooth 60 fps).
///   JS side:     receives each peer's screen position ~15x/sec and draws the HUD (tags, arrows).
final class UwbArView: ExpoView {
    let onPeers = EventDispatcher()
    let onStatus = EventDispatcher()
    var displayName = "Phone"

    private let arView = ARView(frame: .zero)
    private let markerRoot = AnchorEntity(world: .zero)
    private var tracker: UWBTracker?
    private var markers: [MCPeerID: ModelEntity] = [:]
    private var smoothed: [MCPeerID: SIMD3<Float>] = [:]
    private var updateSub: Cancellable?
    private var lastEmit: TimeInterval = 0
    private var lastStatus = ""

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        arView.automaticallyConfigureSession = false
        addSubview(arView)
        arView.scene.addAnchor(markerRoot)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { start() } else { stop() }
    }

    // MARK: Lifecycle

    private func start() {
        guard tracker == nil else { return }
        // Nearby Interaction camera assistance requires gravity alignment and no collaboration.
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.isCollaborationEnabled = false
        arView.session.run(config)

        let t = UWBTracker(arSession: arView.session, displayName: displayName)
        tracker = t
        t.start()
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.tick() }
    }

    private func stop() {
        updateSub?.cancel()
        updateSub = nil
        tracker?.stop()
        tracker = nil
        arView.session.pause()
        markers.values.forEach { $0.removeFromParent() }
        markers.removeAll()
        smoothed.removeAll()
    }

    // MARK: Per frame

    private func tick() {
        guard let tracker, let frame = arView.session.currentFrame else { return }
        let now = CACurrentMediaTime()
        let camera = frame.camera
        let size = bounds.size
        let viewMatrix = camera.viewMatrix(for: .portrait)
        var payload: [[String: Any]] = []
        var seen = Set<MCPeerID>()

        for (peer, r) in tracker.readings {
            seen.insert(peer)
            let stale = r.lastUpdate > 0 && now - r.lastUpdate > 2   // 0 = no reading yet, not "lost"
            var item: [String: Any] = ["id": "\(peer.hash)", "name": r.name, "stale": stale,
                                       "hasPosition": false, "inFront": false, "cameraAssist": r.cameraAssist, "assistActive": r.assistActive,
                                       "x": 0, "y": 0, "dirX": 0, "dirY": 0]
            if let d = r.distance { item["distance"] = Double(d) }
            if let g = r.guidance { item["guidance"] = g }

            if let target = r.worldPosition, !stale {
                // The tracker already filters the readings; this just glides between UWB updates.
                let p = smoothed[peer].map { $0 + (target - $0) * 0.25 } ?? target
                smoothed[peer] = p
                let marker = markers[peer] ?? makeMarker(peer)
                marker.position = p + SIMD3(0, 0.12, 0)
                marker.isEnabled = true

                let cam = viewMatrix * SIMD4(p, 1)   // camera space: -Z is in front
                let s = camera.projectPoint(p, orientation: .portrait, viewportSize: size)
                let len = max(hypot(Double(cam.x), Double(cam.y)), 1e-4)
                item["hasPosition"] = true
                item["inFront"] = cam.z < 0
                item["x"] = Double(s.x)
                item["y"] = Double(s.y)
                item["dirX"] = Double(cam.x) / len          // screen direction, y down
                item["dirY"] = -Double(cam.y) / len
            } else {
                markers[peer]?.isEnabled = false
            }
            payload.append(item)
        }

        for (peer, m) in markers where !seen.contains(peer) {
            m.removeFromParent()
            markers[peer] = nil
            smoothed[peer] = nil
        }

        // ~30 updates/sec so the labels glide with the camera instead of stepping.
        if now - lastEmit >= 0.033 {
            lastEmit = now
            onPeers(["peers": payload])
        }
        if tracker.status != lastStatus {
            lastStatus = tracker.status
            onStatus(["status": tracker.status,
                      "directionSupported": UWBTracker.supportsDirection || UWBTracker.supportsCameraAssistance,
                      "uwbSupported": UWBTracker.isSupported])
        }
    }

    private func makeMarker(_ peer: MCPeerID) -> ModelEntity {
        let m = ModelEntity(mesh: .generateSphere(radius: 0.04),
                            materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)])
        markerRoot.addChild(m)
        markers[peer] = m
        return m
    }
}
