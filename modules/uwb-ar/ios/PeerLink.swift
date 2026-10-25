import MultipeerConnectivity
import NearbyInteraction

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
/// All callbacks arrive on the main queue.
final class PeerLink: NSObject {
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onToken: ((MCPeerID, NIDiscoveryToken) -> Void)?
    var onState: ((MCPeerID, PeerState) -> Void)?
    var onLog: ((String) -> Void)?

    static let serviceType = "uwbhud"            // must match NSBonjourServices in Info.plist
    private static let inviteContext = Data("uwbhud-v1".utf8)

    /// First byte of every message. Builds before this sent a bare archived token, which starts with "b".
    private enum Kind: UInt8 { case token = 1, state = 2 }

    let myPeer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let myRank = UUID().uuidString        // decides who invites whom
    private var invited = Set<MCPeerID>()         // invites in flight, so a re-found peer isn't invited twice

    init(displayName: String) {
        myPeer = MCPeerID(displayName: displayName)
        // .optional avoids the encryption handshake, which has been seen to drop new connections.
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .optional)
        advertiser = MCNearbyServiceAdvertiser(peer: myPeer, discoveryInfo: ["r": myRank],
                                               serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: myPeer, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
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
}

extension PeerLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Both phones see each other; only the one with the lower rank invites.
        guard let theirRank = info?["r"], myRank < theirRank else { return }
        DispatchQueue.main.async {
            // Browsing restarts after every drop, so the same phone is found again and again; a second
            // invite while one is pending or the peer is connected just tears the connection down.
            guard !self.invited.contains(peerID), !self.session.connectedPeers.contains(peerID) else { return }
            self.invited.insert(peerID)
            browser.invitePeer(peerID, to: self.session, withContext: Self.inviteContext, timeout: 15)
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) { self.invited.remove(peerID) }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.onLog?("Can't search for phones: \(error.localizedDescription)") }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.onLog?("Can't advertise: \(error.localizedDescription)") }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(context == Self.inviteContext, session)
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.invited.remove(peerID)
                self.onConnected?(peerID)
            case .notConnected:
                self.invited.remove(peerID)
                self.onDisconnected?(peerID)
                // Search again so the phones find each other and reconnect.
                self.browser.stopBrowsingForPeers()
                self.browser.startBrowsingForPeers()
            default: break
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
