import ARKit
import MultipeerConnectivity
import NearbyInteraction

/// Latest UWB reading for one nearby phone.
struct PeerReading {
    var name: String
    var distance: Float?               // meters, whenever UWB has a reading
    var worldPosition: SIMD3<Float>?   // in OUR ARKit world, once camera assistance has converged
    var guidance: String?              // what the user should do to get a direction fix
    var lastUpdate: TimeInterval = 0
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
    private var tokens: [MCPeerID: NIDiscoveryToken] = [:]   // remembered to restart after interruptions

    static var isSupported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var supportsCameraAssistance: Bool { NISession.deviceCapabilities.supportsCameraAssistance }

    init(arSession: ARSession, displayName: String) {
        self.arSession = arSession
        self.link = PeerLink(displayName: displayName)
        super.init()
        link.onConnected = { [weak self] in self?.connected($0) }
        link.onDisconnected = { [weak self] in self?.disconnected($0) }
        link.onToken = { [weak self] in self?.received(token: $1, from: $0) }
    }

    func start() {
        guard Self.isSupported else { status = "This iPhone has no UWB chip"; return }
        link.start()
        status = "Looking for the other phone…"
    }

    func stop() {
        sessions.values.forEach { $0.invalidate() }
        sessions.removeAll()
        link.stop()
    }

    // MARK: Handshake

    private func connected(_ peer: MCPeerID) {
        status = "Connected to \(peer.displayName). Starting UWB…"
        let s = sessions[peer] ?? makeSession(for: peer)
        if let token = s.discoveryToken { link.send(token: token, to: peer) }
    }

    private func makeSession(for peer: MCPeerID) -> NISession {
        let s = NISession()
        s.delegate = self
        s.delegateQueue = .main
        if Self.supportsCameraAssistance { s.setARSession(arSession) }   // must be set before run()
        sessions[peer] = s
        readings[peer] = PeerReading(name: peer.displayName)
        return s
    }

    private func received(token: NIDiscoveryToken, from peer: MCPeerID) {
        if sessions[peer] == nil { connected(peer) }  // token beat the connect callback
        tokens[peer] = token
        run(peer)
    }

    private func run(_ peer: MCPeerID) {
        guard let s = sessions[peer], let token = tokens[peer] else { return }
        let config = NINearbyPeerConfiguration(peerToken: token)
        if Self.supportsCameraAssistance { config.isCameraAssistanceEnabled = true }
        s.run(config)
        status = "Ranging with \(peer.displayName)"
    }

    private func disconnected(_ peer: MCPeerID) {
        sessions.removeValue(forKey: peer)?.invalidate()
        tokens[peer] = nil
        readings[peer] = nil
        status = link.isConnected ? status : "Looking for the other phone…"
    }

    private func peer(for session: NISession) -> MCPeerID? {
        sessions.first(where: { $0.value === session })?.key
    }
}

extension UWBTracker: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let peer = peer(for: session), let obj = nearbyObjects.first, var r = readings[peer] else { return }
        r.distance = obj.distance
        if let t = session.worldTransform(for: obj) {
            let p = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            r.worldPosition = (p.x.isFinite && p.y.isFinite && p.z.isFinite) ? p : nil
        } else {
            r.worldPosition = nil
        }
        r.lastUpdate = CACurrentMediaTime()
        readings[peer] = r
    }

    /// Camera assistance needs the phone to move a bit before it can work out direction.
    func session(_ session: NISession, didUpdateAlgorithmConvergence convergence: NIAlgorithmConvergence,
                 for object: NINearbyObject?) {
        guard let peer = peer(for: session) else { return }
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
        }
    }

    func sessionWasSuspended(_ session: NISession) {
        status = "UWB paused (app in background?)"
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if let peer = peer(for: session) { run(peer) }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        guard let peer = peer(for: session) else { return }
        status = "UWB restarted: \(error.localizedDescription)"
        sessions[peer] = nil
        // A fresh session has a new token; send it again so the other phone can re-run.
        connected(peer)
        run(peer)
    }
}
