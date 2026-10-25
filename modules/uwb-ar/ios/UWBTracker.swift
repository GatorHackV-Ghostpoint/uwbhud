import ARKit
import MultipeerConnectivity
import NearbyInteraction

/// One Euro filter (https://gery.casiez.net/1euro/): smooths hard while the target is still,
/// and loosens up as it moves so the marker doesn't lag behind someone walking.
struct OneEuroFilter {
    let minCutoff: SIMD3<Float>   // Hz per axis; lower = steadier when still
    let beta: Float               // how fast the cutoff rises with speed
    let dCutoff: Float = 1
    private var x: SIMD3<Float>?
    private var dx = SIMD3<Float>(repeating: 0)
    private var t: TimeInterval = 0

    init(minCutoff: SIMD3<Float>, beta: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private static func alpha(_ cutoff: SIMD3<Float>, _ dt: Float) -> SIMD3<Float> {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ value: SIMD3<Float>, at time: TimeInterval) -> SIMD3<Float> {
        guard let prev = x, time > t else { x = value; t = time; dx = .zero; return value }
        let dt = Float(time - t)
        t = time
        dx += Self.alpha(SIMD3(repeating: dCutoff), dt) * ((value - prev) / dt - dx)
        let speed = SIMD3(abs(dx.x), abs(dx.y), abs(dx.z))
        let next = prev + Self.alpha(minCutoff + beta * speed, dt) * (value - prev)
        x = next
        return next
    }

    mutating func reset() { x = nil }
}

/// Latest UWB reading for one nearby phone.
struct PeerReading {
    var name: String
    var distance: Float?               // meters, whenever UWB has a reading
    var worldPosition: SIMD3<Float>?   // in OUR ARKit world, once camera assistance has converged
    var guidance: String?              // what the user should do to get a direction fix
    var cameraAssist = false           // this peer's session uses camera assistance
    var assistActive = false           // camera assistance has reported in at least once
    var lastUpdate: TimeInterval = 0   // 0 = no reading yet
    var positionTime: TimeInterval = 0 // when worldPosition was last measured
    var recent: [SIMD3<Float>] = []    // last 3 raw positions, for rejecting one-off bad readings
    // Up/down (y) gets a lower cutoff: UWB elevation is the noisiest axis and people rarely move vertically.
    // beta 1.2 (was 0.8): loosens faster when the other person moves, so the marker lags less behind them.
    var positionFilter = OneEuroFilter(minCutoff: SIMD3(0.4, 0.15, 0.4), beta: 1.2)
    var distanceFilter = OneEuroFilter(minCutoff: SIMD3(repeating: 0.5), beta: 0.5)   // only .x is used

    // AR fusion: their own ARKit tracking, streamed over the link, placed in our world by `aligner`.
    var theirPosition: SIMD3<Float>?       // their phone in THEIR AR world
    var theirPositionTime: TimeInterval = 0
    var theirEpoch: UInt32?
    var theirMeasurementSeq: UInt32?       // last of their UWB fixes of us we've used
    var measurement: SIMD3<Float>?         // our latest raw UWB fix of them (our world), streamed to them
    var measurementSeq: UInt32 = 0
    var aligner = PoseAligner()
    var lastPairTime: TimeInterval = 0     // last time UWB tied the two worlds together
}

/// Where to draw a peer this frame.
struct PeerFix {
    var position: SIMD3<Float>   // our AR world
    var distance: Float?
    var fused: Bool              // from their ARKit tracking + alignment, not straight from UWB
    var estimated: Bool          // UWB hasn't confirmed it lately (e.g. behind a wall): their tracking alone
}

/// Per-axis median, so a single reflected reading can't yank the marker.
private func median(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    func mid(_ xs: [Float]) -> Float { xs.sorted()[xs.count / 2] }
    return SIMD3(mid(points.map(\.x)), mid(points.map(\.y)), mid(points.map(\.z)))
}

/// Runs one Nearby Interaction session per nearby phone. With camera assistance,
/// NI fuses UWB with our ARKit tracking and tells us exactly where the other phone
/// is in our AR world, which is all we need to draw a marker on it.
final class UWBTracker: NSObject {
    private(set) var readings: [MCPeerID: PeerReading] = [:]
    private(set) var status = "Starting…"

    private let arSession: ARSession
    private let link: PeerLink
    private var sessions: [MCPeerID: NISession] = [:]
    private var tokens: [MCPeerID: NIDiscoveryToken] = [:]   // their token, remembered to restart after interruptions
    private var restarts: [MCPeerID: Int] = [:]
    private var plainSessions = Set<MCPeerID>()   // peers where iOS rejected camera assistance

    // Our own ARKit pose, shared with the other phones.
    private var epoch: UInt32 = 0                 // bumped when our AR world jumps
    private var myPosition: SIMD3<Float>?         // nil while tracking isn't normal
    private var myPositionTime: TimeInterval = 0
    private var wasRelocalizing = false
    private var lastStateSent: TimeInterval = 0

    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var supportsCameraAssistance: Bool { NISession.deviceCapabilities.supportsCameraAssistance }
    /// iPhone 11–13: UWB alone gives direction. iPhone 14+ only gets direction via camera assistance.
    static var supportsDirection: Bool { NISession.deviceCapabilities.supportsDirectionMeasurement }

    /// Only use camera assistance when it's the sole way to get direction: on iPhone 12 (iOS 26/27)
    /// iOS never issues a discovery token while the camera is attached, even with ARKit tracking fine.
    private func usesAssist(_ peer: MCPeerID) -> Bool {
        Self.supportsCameraAssistance && !Self.supportsDirection && !plainSessions.contains(peer)
    }

    init(arSession: ARSession, displayName: String) {
        self.arSession = arSession
        self.link = PeerLink(displayName: displayName)
        super.init()
        link.onConnected = { [weak self] in self?.connected($0) }
        link.onDisconnected = { [weak self] in self?.disconnected($0) }
        link.onToken = { [weak self] in self?.received(token: $1, from: $0) }
        link.onState = { [weak self] in self?.received(state: $1, from: $0) }
        link.onLog = { [weak self] in self?.note($0) }
    }

    /// Show a step on screen and in the Mac's Console app (search "[UWBHud]").
    private func note(_ text: String) {
        status = text
        NSLog("[UWBHud] %@", text)
    }

    func start() {
        guard Self.isSupported else { note("This iPhone has no UWB chip"); return }
        link.start()
        note("Looking for the other phone…")
    }

    func stop() {
        sessions.values.forEach { $0.invalidate() }
        sessions.removeAll()
        link.stop()
    }

    // MARK: Handshake

    private func connected(_ peer: MCPeerID) {
        note("Connected to \(peer.displayName). Preparing UWB token…")
        if sessions[peer] == nil { _ = makeSession(for: peer) }
        if readings[peer] == nil { readings[peer] = PeerReading(name: peer.displayName) }
        sendToken(to: peer, attempt: 1)
    }

    private func makeSession(for peer: MCPeerID) -> NISession {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = .main
        // Attach the camera straight away: attaching it later (after the token exists) makes
        // iOS reject it with NIERROR_INVALID_AR_SESSION_DESCRIPTION.
        let assist = usesAssist(peer)
        if assist { s.setARSession(arSession) }
        sessions[peer] = s
        readings[peer] = PeerReading(name: peer.displayName, cameraAssist: assist)
        return s
    }

    /// Camera (ARKit) state as NI sees it, for diagnosing camera-assistance problems.
    private var arInfo: String {
        guard let cfg = arSession.configuration else { return "AR not running" }
        guard let world = cfg as? ARWorldTrackingConfiguration else { return "AR: \(type(of: cfg))" }
        let align = world.worldAlignment == .gravity ? "gravity" : "alignment \(world.worldAlignment.rawValue)"
        guard let frame = arSession.currentFrame else { return "AR \(align), no frames" }
        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "tracking ok"
        case .notAvailable: tracking = "tracking unavailable"
        case .limited(let reason): tracking = "tracking limited (\(reason))"
        }
        return String(format: "AR %@, %@, frame %.1fs old", align, tracking, CACurrentMediaTime() - frame.timestamp)
    }

    /// Sends our token, and keeps resending every 2 s until we have theirs (up to 10 tries).
    private func sendToken(to peer: MCPeerID, attempt: Int) {
        guard let s = sessions[peer] else { return }
        guard let token = s.discoveryToken else {
            let assist = usesAssist(peer)
            if assist && attempt == 6 {
                // iOS won't issue a token with the camera attached; carry on with distance only.
                note("Camera assistance gave no token [\(arInfo)]. Distance only…")
                sessions[peer] = nil          // detach first so the invalidate callback ignores it
                s.invalidate()
                plainSessions.insert(peer)
                _ = makeSession(for: peer)
            } else {
                note("Waiting for iOS to create the UWB token (try \(attempt))… [\(assist ? arInfo : "no camera assist")]")
            }
            if attempt < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.sendToken(to: peer, attempt: attempt + 1)
                }
            } else {
                note("iOS never created a UWB token. Check Settings → UWBHud → Nearby Interactions")
            }
            return
        }
        if let err = link.send(token: token, to: peer) {
            note("Token send failed (try \(attempt)): \(err)")
        } else if tokens[peer] == nil {
            note("Sent UWB token to \(peer.displayName) (try \(attempt)). Waiting for theirs…")
        }
        guard tokens[peer] == nil, attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.tokens[peer] == nil, self.link.isConnected(peer) else { return }
            self.sendToken(to: peer, attempt: attempt + 1)
        }
    }

    private func received(token: NIDiscoveryToken, from peer: MCPeerID) {
        if sessions[peer] == nil {
            // Token beat the connect callback, or our session just failed. Don't rebuild a
            // session that keeps failing: that's what made the status flip endlessly.
            guard (restarts[peer] ?? 0) <= 3 else { return }
            connected(peer)
        }
        let isRepeat = tokens[peer] == token
        if isRepeat {
            // They're resending, so they haven't got ours yet. Reply once more.
            sendToken(to: peer, attempt: 10)
            return
        }
        tokens[peer] = token
        note("Got token from \(peer.displayName). Starting UWB…")
        run(peer)
        sendToken(to: peer, attempt: 10)   // make sure they have ours too
    }

    private func run(_ peer: MCPeerID) {
        guard let s = sessions[peer], let token = tokens[peer] else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if usesAssist(peer) { config.isCameraAssistanceEnabled = true }
        s.run(config)
        note("UWB started with \(peer.displayName). Waiting for first reading…")
    }

    private func disconnected(_ peer: MCPeerID) {
        // Keep the UWB session: once tokens are swapped, UWB keeps working without this link,
        // and tearing it down mid-setup is what killed the token before.
        if tokens[peer] == nil {
            note("Link to \(peer.displayName) dropped before UWB started. Reconnecting…")
        } else {
            note("Link to \(peer.displayName) dropped; UWB continues")
        }
    }

    private func peer(for session: NISession) -> MCPeerID? {
        sessions.first(where: { $0.value === session })?.key
    }

    // MARK: AR fusion

    /// Call every AR frame: tracks our pose and streams it (with our latest UWB fix) ~30x/sec.
    func update(with frame: ARFrame) {
        let now = CACurrentMediaTime()
        var normal = false, relocalizing = false
        switch frame.camera.trackingState {
        case .normal: normal = true
        case .limited(.relocalizing): relocalizing = true
        default: break
        }
        let t = frame.camera.transform.columns.3
        let pos = SIMD3(t.x, t.y, t.z)
        // ARKit moved our world (relocalized, or snapped >30 cm in one frame): every pair so far is in the old one.
        let snapped = myPosition.map { simd_distance($0, pos) > 0.3 && now - myPositionTime < 0.1 } ?? false
        if (wasRelocalizing && !relocalizing) || snapped {
            epoch &+= 1
            for peer in readings.keys {
                readings[peer]?.aligner.reset()
                readings[peer]?.measurement = nil
            }
            NSLog("[UWBHud] AR world jumped; re-aligning")
        }
        wasRelocalizing = relocalizing
        myPosition = normal ? pos : nil
        myPositionTime = now

        guard now - lastStateSent >= 1.0 / 30 else { return }
        lastStateSent = now
        for (peer, r) in readings {
            let fresh = r.measurement != nil && now - r.positionTime < 0.5
            link.send(state: PeerState(epoch: epoch, position: myPosition, measurementSeq: r.measurementSeq,
                                       measurement: fresh ? r.measurement : nil), to: peer)
        }
    }

    private func received(state: PeerState, from peer: MCPeerID) {
        guard var r = readings[peer] else { return }
        let now = CACurrentMediaTime()
        if r.theirEpoch != state.epoch {   // their world jumped: old pairs are meaningless
            r.aligner.reset()
            r.theirEpoch = state.epoch
            r.theirMeasurementSeq = nil
        }
        r.theirPosition = state.position
        r.theirPositionTime = now
        // Their UWB fix of us (their world) ↔ where we are (our world).
        if let m = state.measurement, state.measurementSeq != r.theirMeasurementSeq, let me = myPosition {
            r.theirMeasurementSeq = state.measurementSeq
            r.aligner.add(theirs: m, ours: me, at: now)
            r.lastPairTime = now
        }
        readings[peer] = r
    }

    /// Where to draw the peer now: their own tracking mapped into our world once the alignment is solid,
    /// otherwise the UWB position. Holds through UWB dropouts for up to 30 s while their poses keep coming.
    func fix(for peer: MCPeerID, at now: TimeInterval) -> PeerFix? {
        guard let r = readings[peer] else { return nil }
        let uwbFresh = r.lastUpdate > 0 && now - r.lastUpdate <= 2
        if let b = r.theirPosition, now - r.theirPositionTime < 0.5, now - r.lastPairTime < 30,
           let q = readings[peer]?.aligner.map(b, at: now) {
            let estimated = now - r.lastPairTime > 1.5
            let distance = uwbFresh ? r.distance : myPosition.map { simd_distance($0, q) }
            return PeerFix(position: q, distance: distance, fused: true, estimated: estimated)
        }
        guard uwbFresh, let p = r.worldPosition else { return nil }
        return PeerFix(position: p, distance: r.distance, fused: false, estimated: false)
    }
}

extension UWBTracker: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peer = peer(for: session), let obj = nearbyObjects.first, var r = readings[peer] else { return }
        if r.lastUpdate == 0 { note("Ranging with \(peer.displayName)") }
        let now = CACurrentMediaTime()
        if let d = obj.distance { r.distance = r.distanceFilter.filter(SIMD3(repeating: d), at: now).x }
        var p: SIMD3<Float>?
        if let t = session.worldTransform(for: obj) {
            p = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        } else if let dir = obj.direction, let d = obj.distance, let frame = arSession.currentFrame {
            // No camera-assisted fix (e.g. iPhone 11–13 without assistance): UWB's own direction is
            // relative to the phone held upright (x right, y up, -z out the back), same as the
            // portrait camera space, so place it in the AR world through the current camera pose.
            let w = frame.camera.viewMatrix(for: .portrait).inverse * SIMD4(dir * d, 1)
            p = SIMD3(w.x, w.y, w.z)
        }
        if let q = p, q.x.isFinite, q.y.isFinite, q.z.isFinite {
            // Our UWB fix of them (our world) ↔ their streamed position (their world), taken together.
            r.measurement = q
            r.measurementSeq &+= 1
            if let b = r.theirPosition, now - r.theirPositionTime < 0.25, myPosition != nil {
                r.aligner.add(theirs: b, ours: q, at: now)
                r.lastPairTime = now
            }
            if now - r.positionTime > 1.5 {   // after a real gap, start fresh rather than sliding from the old spot
                r.recent.removeAll()
                r.positionFilter.reset()
            }
            r.recent.append(q)
            if r.recent.count > 3 { r.recent.removeFirst() }   // 3, not 5: one reading less delay
            r.worldPosition = r.positionFilter.filter(median(r.recent), at: now)
            r.positionTime = now
        } else if now - r.positionTime > 1.5 {
            r.worldPosition = nil   // UWB often skips direction for a reading or two; only drop it after a real gap
        }
        r.lastUpdate = now
        readings[peer] = r
    }

    /// Camera assistance needs the phone to move a bit before it can work out direction.
    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence,
                 for object: NINearbyObject?) {
        guard let peer = peer(for: session) else { return }
        readings[peer]?.assistActive = true
        switch convergence.status {
        case .converged:
            readings[peer]?.guidance = nil
        case .notConverged(let reasons):
            if reasons.contains(.insufficientLighting) {
                readings[peer]?.guidance = "Need more light"
            } else if reasons.contains(.insufficientHorizontalSweep) {
                readings[peer]?.guidance = "Sweep phone slowly left and right"
            } else if reasons.contains(.insufficientVerticalSweep) {
                readings[peer]?.guidance = "Tilt phone slowly up and down"
            } else {
                readings[peer]?.guidance = "Move the phone around a little"
            }
        default:
            readings[peer]?.guidance = "Move the phone around a little"
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peer = peer(for: session) else { return }
        if reason == .timeout {
            readings[peer]?.worldPosition = nil   // out of range / blocked; keep session for when they return
            note("UWB timed out with \(peer.displayName) (out of range or blocked?)")
        } else if reason == .peerEnded {
            note("\(peer.displayName) stopped UWB")
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        note("UWB paused (app in background?)")
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let peer = peer(for: session) { run(peer) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let peer = peer(for: session) else { return }
        let code = (error as NSError).code
        if let ni = error as? NIError, ni.code == .userDidNotAllow {
            note("Nearby Interaction not allowed. Turn it on: Settings → UWBHud → Nearby Interactions")
        } else if let ni = error as? NIError, ni.code == .invalidARConfiguration, !plainSessions.contains(peer) {
            // Keep distance working rather than failing outright; direction needs camera assistance.
            plainSessions.insert(peer)
            note("iOS rejected camera assistance (\(error.localizedDescription)). Distance only for \(peer.displayName)")
        } else {
            note("UWB error \(code): \(error.localizedDescription) [\(arInfo)]")
        }
        sessions[peer] = nil
        let n = (restarts[peer] ?? 0) + 1
        restarts[peer] = n
        guard n <= 3, link.isConnected(peer) else { return }   // don't loop forever
        // A fresh session has a new token; send it so the other phone can re-run with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.sessions[peer] == nil else { return }   // a new token may have rebuilt it already
            _ = self.makeSession(for: peer)
            self.sendToken(to: peer, attempt: 1)
            self.run(peer)
        }
    }
}
