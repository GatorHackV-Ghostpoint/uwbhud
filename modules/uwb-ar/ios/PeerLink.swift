import MultipeerConnectivity
import NearbyInteraction

/// Finds nearby phones running this app and delivers their UWB discovery tokens.
/// Uses Wi-Fi/Bluetooth directly between phones: no internet or server needed.
/// All callbacks arrive on the main queue.
final class PeerLink: NSObject {
    var onConnected: ((MCPeerID) -> Void)?
    var onDisconnected: ((MCPeerID) -> Void)?
    var onToken: ((MCPeerID, NIDiscoveryToken) -> Void)?

    static let serviceType = "uwbhud"            // must match NSBonjourServices in Info.plist
    private static let inviteContext = Data("uwbhud-v1".utf8)

    let myPeer: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private let myRank = UUID().uuidString        // decides who invites whom

    init(displayName: String) {
        myPeer = MCPeerID(displayName: displayName)
        session = MCSession(peer: myPeer, securityIdentity: nil, encryptionPreference: .required)
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

    func send(token: NIDiscoveryToken, to peer: MCPeerID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    var isConnected: Bool { !session.connectedPeers.isEmpty }
}

extension PeerLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Both phones see each other; only the one with the lower rank invites.
        guard let theirRank = info?["r"], myRank < theirRank else { return }
        browser.invitePeer(peerID, to: session, withContext: Self.inviteContext, timeout: 15)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(context == Self.inviteContext, session)
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected: self.onConnected?(peerID)
            case .notConnected: self.onDisconnected?(peerID)
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: data) else { return }
        DispatchQueue.main.async { self.onToken?(peerID, token) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
