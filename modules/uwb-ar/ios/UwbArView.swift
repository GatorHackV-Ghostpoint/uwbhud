import ARKit
import Combine
import ExpoModulesCore
import MultipeerConnectivity
import RealityKit

/// Native camera view for React Native.
///   Native side: camera, UWB ranging, AR pose sharing, person snapping, 3D marker dots and on-screen
///   name tags, every frame.
///   JS side:     receives each peer's state ~30x/sec and draws the rest of the HUD (edge arrows, cards).
/// Tags are native because a JS tag trails the camera image by several frames (event bridge +
/// React render), sliding off the person whenever the phone pans.
final class UwbArView: ExpoView {
    let onPeers = EventDispatcher()
    let onStatus = EventDispatcher()
    var displayName = "Phone"
    /// Manual pairing: only connect to phones using this code. Empty = any nearby phone running the app.
    /// Changing it re-pairs from scratch (the camera keeps running).
    var pairingCode = "" {
        didSet {
            guard pairingCode != oldValue, tracker != nil else { return }
            stopTracker()
            startTracker()
        }
    }
    /// Changing this tears down every connection and UWB session and pairs again from scratch, keeping the code.
    var resetKey = 0.0 {
        didSet {
            guard resetKey != oldValue, tracker != nil else { return }
            stopTracker()
            startTracker()
        }
    }
    /// Screen margins kept clear for the JS HUD; a peer outside them gets an edge arrow instead of a tag.
    var tagInsets = (top: 130.0, bottom: 150.0, side: 30.0)

    private let arView = ARView(frame: .zero)
    private let markerRoot = AnchorEntity(world: .zero)
    private var tracker: UWBTracker?
    private var waypointOverlay: WaypointOverlay?
    private let snapper = PersonSnapper()
    private var markers: [MCPeerID: ModelEntity] = [:]
    private let tagLayer = UIView()
    private var tags: [MCPeerID: PeerTagView] = [:]
    private var smoothed: [MCPeerID: SIMD3<Float>] = [:]
    private var snapOffset: [MCPeerID: SIMD3<Float>] = [:]   // camera correction as shown, eased in and out
    private var lastTick: TimeInterval = 0
    private var updateSub: Cancellable?
    private var lastEmit: TimeInterval = 0
    private var lastStatus = ""
    private var lastTimeline = ""

    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        clipsToBounds = true
        arView.automaticallyConfigureSession = false
        addSubview(arView)
        tagLayer.isUserInteractionEnabled = false
        addSubview(tagLayer)
        arView.scene.addAnchor(markerRoot)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds
        tagLayer.frame = bounds
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
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.run(config)
        startTracker()
        updateSub = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.tick() }
    }

    private func stop() {
        updateSub?.cancel()
        updateSub = nil
        stopTracker()
        arView.session.pause()
    }

    private func startTracker() {
        let t = UWBTracker(arSession: arView.session, displayName: displayName,
                           pairingCode: pairingCode.isEmpty ? nil : pairingCode)
        tracker = t
        t.start()
        waypointOverlay = WaypointOverlay(arView: arView, tracker: t, container: tagLayer)
        snapper.onMatch = { [weak t] peer, snap, target in
            t?.addCameraFix(for: peer, point: snap.point, target: target, at: snap.time)
        }
    }

    private func stopTracker() {
        waypointOverlay?.stop()
        waypointOverlay = nil
        tracker?.stop()
        tracker = nil
        lastStatus = ""
        lastTimeline = ""
        markers.values.forEach { $0.removeFromParent() }
        markers.removeAll()
        tags.values.forEach { $0.removeFromSuperview() }
        tags.removeAll()
        smoothed.removeAll()
        snapOffset.removeAll()
        snapper.reset()
    }

    // MARK: Per frame

    private func tick() {
        guard let tracker, let frame = arView.session.currentFrame else { return }
        tracker.update(with: frame)
        waypointOverlay?.tick(camera: frame.camera)
        let now = CACurrentMediaTime()
        let dt = Float(min(max(now - lastTick, 0), 0.1))   // time-based easing: same feel at any frame rate
        lastTick = now
        let camera = frame.camera
        let size = bounds.size
        let viewMatrix = camera.viewMatrix(for: .portrait)
        var payload: [[String: Any]] = []
        var seen = Set<MCPeerID>()
        var targets: [MCPeerID: PersonSnapper.Target] = [:]

        for (peer, r) in tracker.readings {
            seen.insert(peer)
            let fix = tracker.fix(for: peer, at: now)
            // 0 = no reading yet, not "lost". Their streamed AR pose keeps a peer alive through UWB dropouts.
            let stale = r.lastUpdate > 0 && now - r.lastUpdate > 2 && fix == nil
            var item: [String: Any] = ["id": "\(peer.hash)", "name": r.name, "stale": stale,
                                       "hasPosition": false, "inFront": false, "onScreen": false, "cameraAssist": r.cameraAssist, "assistActive": r.assistActive,
                                       "fused": fix?.fused ?? false, "estimated": fix?.estimated ?? false, "snapped": false,
                                       "x": 0, "y": 0, "dirX": 0, "dirY": 0]
            let distance = fix?.distance ?? r.distance
            if let d = distance { item["distance"] = Double(d) }
            if let g = r.guidance { item["guidance"] = g }

            var tagPoint: CGPoint?
            var snapped = false
            if let fix {
                targets[peer] = PersonSnapper.Target(ours: fix.position, theirs: r.theirPredicted(at: now))
                // On camera: shift onto the matched person. The correction eases in over ~0.3 s when the camera
                // finds them and eases back out over ~2 s when it loses them, so neither is a jump.
                var goal = SIMD3<Float>(repeating: 0)
                if let snap = snapper.snaps[peer], now - snap.time < 0.25 {
                    goal = snap.offset
                    snapped = true
                }
                let shown = snapOffset[peer] ?? .zero
                let offset = shown + (goal - shown) * (1 - exp(-dt / (snapped ? 0.1 : 0.7)))
                snapOffset[peer] = offset
                let target = fix.position + offset
                item["snapped"] = snapped
                // UWB positions step at the ranging rate, so glide between them more. A fused position already
                // moves with their own tracking; this just softens hand shake and alignment updates.
                let k = 1 - exp(-dt / (fix.fused ? 0.06 : 0.12))
                let p = smoothed[peer].map { $0 + (target - $0) * k } ?? target
                smoothed[peer] = p
                let marker = markers[peer] ?? makeMarker(peer)
                marker.position = p   // exactly at the measured point; the tag sits just above it
                marker.isEnabled = true

                let cam = viewMatrix * SIMD4(p, 1)   // camera space: -Z is in front
                let inFront = cam.z < 0
                // arView.project uses the same camera as the frame being drawn, so the tag stays on the sphere.
                let s = (inFront ? arView.project(p) : nil)
                    ?? camera.projectPoint(p, orientation: .portrait, viewportSize: size)
                let len = max(hypot(Double(cam.x), Double(cam.y)), 1e-4)
                let onScreen = inFront
                    && Double(s.x) > tagInsets.side && Double(s.x) < Double(size.width) - tagInsets.side
                    && Double(s.y) > tagInsets.top && Double(s.y) < Double(size.height) - tagInsets.bottom
                if onScreen { tagPoint = s }
                item["hasPosition"] = true
                item["inFront"] = inFront
                item["onScreen"] = onScreen
                item["x"] = Double(s.x)
                item["y"] = Double(s.y)
                item["dirX"] = Double(cam.x) / len          // screen direction, y down
                item["dirY"] = -Double(cam.y) / len
            } else {
                markers[peer]?.isEnabled = false
            }
            updateTag(peer, name: r.name, distance: distance, fused: fix?.fused ?? false,
                      estimated: fix?.estimated ?? false, snapped: snapped, at: tagPoint)
            payload.append(item)
        }

        for (peer, m) in markers where !seen.contains(peer) {
            m.removeFromParent()
            markers[peer] = nil
            smoothed[peer] = nil
            snapOffset[peer] = nil
        }
        for (peer, tag) in tags where !seen.contains(peer) {
            tag.removeFromSuperview()
            tags[peer] = nil
        }
        snapper.process(frame, targets: targets)

        // ~30 updates/sec so the labels glide with the camera instead of stepping.
        if now - lastEmit >= 0.033 {
            lastEmit = now
            onPeers(["peers": payload])
        }
        let timeline = tracker.timeline.last ?? ""
        if tracker.status != lastStatus || timeline != lastTimeline {
            lastStatus = tracker.status
            lastTimeline = timeline
            onStatus(["status": tracker.status, "timeline": tracker.timeline, "pairingCode": pairingCode,
                      "directionSupported": UWBTracker.supportsDirection || UWBTracker.supportsCameraAssistance,
                      "uwbSupported": UWBTracker.isSupported])
        }
    }

    /// Shows the peer's tag with its bottom edge just above `point` (the sphere), or hides it.
    private func updateTag(_ peer: MCPeerID, name: String, distance: Float?, fused: Bool, estimated: Bool,
                           snapped: Bool, at point: CGPoint?) {
        guard let point else {
            tags[peer]?.isHidden = true
            return
        }
        let tag: PeerTagView
        if let existing = tags[peer] {
            tag = existing
        } else {
            tag = PeerTagView(name: name)
            tagLayer.addSubview(tag)
            tags[peer] = tag
        }
        tag.isHidden = false
        tag.setDistance(distance, fused: fused, estimated: estimated, snapped: snapped)
        tag.alpha = estimated ? 0.55 : 1
        tag.center = CGPoint(x: point.x, y: point.y - 14 - tag.bounds.height / 2)
    }

    private func makeMarker(_ peer: MCPeerID) -> ModelEntity {
        let m = ModelEntity(mesh: .generateSphere(radius: 0.04),
                            materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)])
        markerRoot.addChild(m)
        markers[peer] = m
        return m
    }
}

/// Green name + distance pill, matching the JS HUD's style.
private final class PeerTagView: UIView {
    private let nameLabel = UILabel()
    private let distanceLabel = UILabel()

    init(name: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 170, height: 48))
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 0.85)
        layer.cornerRadius = 12
        nameLabel.font = .systemFont(ofSize: 15, weight: .bold)
        distanceLabel.font = .systemFont(ofSize: 13)
        for label in [nameLabel, distanceLabel] {
            label.textColor = .white
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75
        }
        nameLabel.text = name
        let stack = UIStackView(arrangedSubviews: [nameLabel, distanceLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.frame = bounds.insetBy(dx: 4, dy: 6)
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// "~" while UWB isn't confirming the position; "· AR" when it comes from their ARKit tracking;
    /// "· CAM" while it's snapped to the person on camera.
    func setDistance(_ meters: Float?, fused: Bool, estimated: Bool, snapped: Bool) {
        // Same format as the JS HUD's formatDistance.
        var text = meters.map { $0 < 10 ? String(format: "%.2f m", $0) : String(format: "%.1f m", $0) } ?? "—"
        if estimated { text = "~" + text }
        if fused { text += " · AR" }
        if snapped { text += " · CAM" }
        if distanceLabel.text != text { distanceLabel.text = text }
    }
}
