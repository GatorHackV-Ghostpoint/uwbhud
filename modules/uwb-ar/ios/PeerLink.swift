import MultipeerConnectivity
import NearbyInteraction
import QuartzCore

/// What each phone streams to the other every AR frame (60x/sec) once linked, so the receiver can follow the sender
/// with the sender's own ARKit tracking (see PoseAligner).
struct PeerState {
    var time: UInt32                // sender's clock (ms, wraps), for velocity from when poses were taken
    var epoch: UInt32               // bumped whenever the sender's AR world jumps (relocalization)
    var position: SIMD3<Float>?     // sender's phone in the sender's AR world; nil while tracking is poor
    var measurementSeq: UInt32      // bumped with each new UWB fix below
    var measurement: SIMD3<Float>?  // where the sender's UWB last put the receiver, in the sender's AR world

    // Wire format (little-endian): time u32, epoch u32, flags u8, position 3×f32, seq u32, measurement 3×f32.
    static let byteCount = 37

    func encoded() -> Data {
        var d = Data(capacity: Self.byteCount)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func vec(_ p: SIMD3<Float>?) { let p = p ?? .zero; [p.x, p.y, p.z].forEach { u32($0.bitPattern) } }
        u32(time)
        u32(epoch)
        d.append((position != nil ? 1 : 0) | (measurement != nil ? 2 : 0))
        vec(position)
        u32(measurementSeq)
        vec(measurement)
        return d
    }

    init(time: UInt32, epoch: UInt32, position: SIMD3<Float>?, measurementSeq: UInt32, measurement: SIMD3<Float>?) {
        self.time = time
        self.epoch = epoch
        self.position = position
        self.measurementSeq = measurementSeq
        self.measurement = measurement
    }

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.byteCount else { return nil }
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[i + $1]) << (8 * $1) } }
        func vec(_ i: Int) -> SIMD3<Float> {
            SIMD3(Float(bitPattern: u32(i)), Float(bitPattern: u32(i + 4)), Float(bitPattern: u32(i + 8)))
        }
        time = u32(0)
        epoch = u32(4)
        position = b[8] & 1 != 0 ? vec(9) : nil
        measurementSeq = u32(21)
        measurement = b[8] & 2 != 0 ? vec(25) : nil
    }
}

/// Finds nearby phones running this app, delivers their UWB discovery tokens, and carries the
/// AR pose stream. Uses Wi-Fi/Bluetooth directly between phones: no internet or server needed.
/// With a pairing code, only phones using the same code connect; otherwise any phone running the app.
/// All callbacks arrive on the main queue.
final class PeerLink: NSObject {
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onToken: ((MCPeerID, NIDiscoveryToken) -> Void)?
    var onState: ((MCPeerID, PeerState) -> Void)?
    var onLog: ((String) -> Void)?     // shown as the status line
    var onEvent: ((String) -> Void)?   // pairing timeline only

    static let serviceType = "uwbhud"            // must match NSBonjourServices in Info.plist
    static let inviteTimeout: TimeInterval = 8
    /// The higher-ranked phone waits this long for the other's invite before inviting itself.
    static let inviteGrace: TimeInterval = 3

    /// First byte of every message. Builds before this sent a bare archived token, which starts with "b".
    private enum Kind: UInt8 { case token = 1, state = 2 }

    private struct Found {
        var rank: String
        var since: TimeInterval
    }

    let myPeer: MCPeerID
    let code: String?
    private let inviteContext: Data
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let myRank = UUID().uuidString        // decides who invites first
    private var found: [MCPeerID: Found] = [:]    // visible phones with our code (or none, in automatic mode)
    private var invited: [MCPeerID: TimeInterval] = [:]   // our invites in flight, by when sent
    private var connecting = Set<MCPeerID>()
    private var retry: Timer?

    init(displayName: String, code: String?) {
        myPeer = MCPeerID(displayName: displayName)
        self.code = code
        inviteContext = Data(("uwbhud-v2" + (code.map { ":" + $0 } ?? "")).utf8)
        // .optional avoids the encryption handshake, which has been seen to drop new connections.
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .optional)
        var info = ["r": myRank]
        if let code { info["c"] = code }
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: info, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        // Invites are retried on a timer, not only when a phone is (re)discovered: Bonjour reports a phone
        // once, so a lost invite used to mean waiting until discovery happened to fire again.
        retry = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.inviteDue() }
    }

    func stop() {
        retry?.invalidate()
        retry = nil
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    /// Returns nil on success, or a description of what went wrong.
    func send(token: NIDiscoveryToken, to peer: MCPeerID) -> String? {
        guard session.connectedPeers.contains(peer) else { return "not connected to \(peer.displayName) yet" }
        do {
            var data = Data([Kind.token.rawValue])
            data.append(try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true))
            try session.send(data, toPeers: [peer], with: .reliable)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Fire-and-forget: a lost pose is replaced by the next one 17 ms later, so no retransmits.
    func send(state: PeerState, to peer: MCPeerID) {
        guard session.connectedPeers.contains(peer) else { return }
        var data = Data([Kind.state.rawValue])
        data.append(state.encoded())
        try? session.send(data, toPeers: [peer], with: .unreliable)
    }

    func isConnected(_ peer: MCPeerID) -> Bool { session.connectedPeers.contains(peer) }
    var isConnected: Bool { !session.connectedPeers.isEmpty }

    /// Invites every visible phone we aren't connected or connecting to. The lower rank invites at once;
    /// the higher rank also invites after a grace period, because discovery is often one-way (right after
    /// launch, or at range) and the lower-ranked phone may not see us at all.
    private func inviteDue() {
        let now = CACurrentMediaTime()
        for (peer, f) in found {
            guard !session.connectedPeers.contains(peer), !connecting.contains(peer) else { continue }
            if let sent = invited[peer], now - sent < Self.inviteTimeout + 1 { continue }
            guard myRank < f.rank || now - f.since > Self.inviteGrace else { continue }
            invited[peer] = now
            onEvent?("Inviting \(peer.displayName)")
            browser.invitePeer(peer, to: session, withContext: inviteContext, timeout: Self.inviteTimeout)
        }
    }
}

extension PeerLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard let rank = info?["r"] else { return }
            guard info?["c"] == self.code else {
                self.onEvent?("Ignoring \(peerID.displayName): " + (info?["c"] == nil ? "not using a code" : "different code"))
                return
            }
            if self.found[peerID] == nil {
                self.found[peerID] = Found(rank: rank, since: CACurrentMediaTime())
                self.onEvent?("Found \(peerID.displayName)")
            }
            self.inviteDue()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            guard self.found.removeValue(forKey: peerID) != nil else { return }
            self.onEvent?("Lost sight of \(peerID.displayName)")
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.onLog?("Can't search for phones: \(error.localizedDescription)") }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.onLog?("Can't advertise: \(error.localizedDescription)") }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            // Same code (or both automatic), and not already linked: accepting a second time breaks the first.
            // If both phones invited each other at once, the lower rank's invite is the one that goes through.
            let crossed = self.invited[peerID] != nil && self.myRank < (self.found[peerID]?.rank ?? "")
            let accept = context == self.inviteContext && !crossed
                && !self.session.connectedPeers.contains(peerID) && !self.connecting.contains(peerID)
            self.onEvent?("\(peerID.displayName) invited us: " + (accept ? "accepted" : "declined"))
            invitationHandler(accept, self.session)
        }
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connecting:
                self.connecting.insert(peerID)
                self.onEvent?("Connecting to \(peerID.displayName)…")
            case .connected:
                self.connecting.remove(peerID)
                self.invited[peerID] = nil
                self.onEvent?("Linked with \(peerID.displayName)")
                self.onConnected?(peerID)
            case .notConnected:
                let wasLinked = !self.connecting.contains(peerID)
                self.connecting.remove(peerID)
                self.invited[peerID] = nil   // retry on the next tick instead of waiting out the timeout
                self.found[peerID]?.since = CACurrentMediaTime()   // give the lower rank first go again
                self.onEvent?(wasLinked ? "Link to \(peerID.displayName) dropped" : "Couldn't connect to \(peerID.displayName)")
                self.onDisconnected?(peerID)
                // Search again so a phone that went out of range is reported when it's back.
                self.browser.stopBrowsingForPeers()
                self.browser.startBrowsingForPeers()
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let kind = data.first.flatMap(Kind.init(rawValue:))
        let body = kind == nil ? data : Data(data.dropFirst())
        if kind == .state {
            guard let state = PeerState(body) else { return }
            DispatchQueue.main.async { self.onState?(peerID, state) }
            return
        }
        let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: body)
        DispatchQueue.main.async {
            if let token { self.onToken?(peerID, token) }
            else { self.onLog?("Got \(data.count) bytes from \(peerID.displayName) but it wasn't a UWB token") }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
