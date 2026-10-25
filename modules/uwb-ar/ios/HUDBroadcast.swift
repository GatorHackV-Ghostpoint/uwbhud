import ExpoModulesCore
import ReplayKit
import UIKit
import WebRTC

// Controls/signaling stay on the main queue. ReplayKit buffers never cross into JS.
final class HUDBroadcast: NSObject, RTCPeerConnectionDelegate, RPScreenRecorderDelegate {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    var onStatus: ((String, String?) -> Void)?
    private let recorder = RPScreenRecorder.shared()
    private var pc: RTCPeerConnection?
    private let frameLock = NSLock()
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var lastFrame: Int64 = 0
    private var frameGeneration: UUID?
    private var generation = UUID()
    private var endpoint: URL?
    private var authorization = ""
    private var resource: URL?
    private var timeout: DispatchWorkItem?
    private var offerSent = false
    private var stoppingCapture = false
    private var startingCapture = false
    private let session = URLSession(configuration: .ephemeral, delegate: WHIPNoRedirects(), delegateQueue: nil)
    private var backgroundObserver: NSObjectProtocol?

    override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        session.invalidateAndCancel()
    }

    func start(endpoint value: String, password: String) throws {
        guard pc == nil, !stoppingCapture, !startingCapture else { throw failure("Broadcast is busy; stop it before restarting.") }
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path == "/media/hud/whip" else {
            throw failure("Enter the HTTPS HUD WHIP URL.")
        }
        guard recorder.isAvailable, !recorder.isRecording else { throw failure("Screen capture is unavailable or already in use.") }
        generation = UUID()
        let run = generation
        endpoint = url
        authorization = password.isEmpty ? "" : "Basic " + Data("hud-publisher:\(password)".utf8).base64EncodedString()
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [] // Public server candidates arrive in the WHIP answer.
        guard let connection = Self.factory.peerConnection(with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self) else {
            throw failure("Could not create WebRTC connection.")
        }
        pc = connection
        let videoSource = Self.factory.videoSource(forScreenCast: true)
        // Keep the original aspect ratio: forcing 16:9 would crop a tall iPhone HUD.
        frameLock.lock()
        source = videoSource
        capturer = RTCVideoCapturer(delegate: videoSource)
        frameGeneration = run
        lastFrame = 0
        frameLock.unlock()
        let track = Self.factory.videoTrack(with: videoSource, trackId: "hud-video")
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .sendOnly
        connection.addTransceiver(with: track, init: transceiver)
        // No audio source/track, microphone, camera capture, or recording output.
        recorder.isMicrophoneEnabled = false
        recorder.isCameraEnabled = false
        recorder.delegate = self
        offerSent = false
        startingCapture = true
        onStatus?("starting", nil)
        armTimeout(run, message: "Capture or WebRTC connection timed out.")
        recorder.startCapture(handler: { [weak self] sample, type, error in
            guard let self else { return }
            if error != nil {
                DispatchQueue.main.async { if self.generation == run { self.fail("Screen capture failed.") } }
                return
            }
            guard type == .video, CMSampleBufferIsValid(sample),
                  let pixels = CMSampleBufferGetImageBuffer(sample), self.frameLock.try() else { return }
            defer { self.frameLock.unlock() }
            guard self.frameGeneration == run, let source = self.source, let capturer = self.capturer else { return }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time.isFinite else { return }
            let ns = Int64(time * 1_000_000_000)
            guard ns - self.lastFrame >= 50_000_000 else { return }
            self.lastFrame = ns
            // App is portrait locked. Honor ReplayKit orientation metadata for rotated buffers.
            let orientation = CMGetAttachment(sample, key: RPVideoSampleOrientationKey as CFString,
                                               attachmentModeOut: nil) as? NSNumber
            let rotation: RTCVideoRotation
            switch orientation?.intValue {
            case 3: rotation = ._180
            case 6: rotation = ._90
            case 8: rotation = ._270
            default: rotation = ._0
            }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: rotation, timeStampNs: ns)
            source.capturer(capturer, didCapture: frame)
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.startingCapture = false
                guard self.generation == run else { self.stopCapture(); return }
                if error != nil { self.fail("Screen capture permission was declined or capture could not start."); return }
                self.onStatus?("connecting", nil)
                connection.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { offer, error in
                    DispatchQueue.main.async {
                        guard self.generation == run else { return }
                        guard let offer, error == nil else { self.fail("Could not create video offer."); return }
                        connection.setLocalDescription(offer) { error in
                            DispatchQueue.main.async {
                                guard self.generation == run else { return }
                                if error != nil { self.fail("Could not set video offer.") }
                                else if connection.iceGatheringState == .complete { self.publish(run) }
                            }
                        }
                    }
                }
            }
        })
    }

    func stop() {
        generation = UUID()
        timeout?.cancel(); timeout = nil
        frameLock.lock()
        source = nil; capturer = nil; frameGeneration = nil
        frameLock.unlock()
        pc?.close(); pc = nil
        if let resource { delete(resource, auth: authorization) }
        resource = nil; endpoint = nil; authorization = ""
        stopCapture()
        onStatus?("stopped", nil)
    }

    private func stopCapture() {
        guard recorder.isRecording, !startingCapture, !stoppingCapture else { return }
        stoppingCapture = true
        recorder.stopCapture { [weak self] _ in
            DispatchQueue.main.async { self?.stoppingCapture = false }
        }
    }

    private func fail(_ message: String) { stop(); onStatus?("error", message) }
    func screenRecorder(_ screenRecorder: RPScreenRecorder, didStopRecordingWith previewViewController: RPPreviewViewController?, error: Error?) {
        DispatchQueue.main.async {
            if self.pc != nil { self.fail("Screen capture was interrupted. Start Broadcast to try again.") }
        }
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "HUDBroadcast", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func armTimeout(_ run: UUID, message: String) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == run else { return }
            self.fail(message)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }
    private func publish(_ run: UUID) {
        guard generation == run, !offerSent, let endpoint, let sdp = pc?.localDescription?.sdp else { return }
        offerSent = true
        let auth = authorization
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.httpBody = Data(sdp.utf8)
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let http = response as? HTTPURLResponse
                let location = http?.value(forHTTPHeaderField: "Location")
                let candidate = location.flatMap { URL(string: $0, relativeTo: endpoint)?.absoluteURL }
                // Never forward credentials to an origin supplied by a redirect/Location.
                let safe = candidate.flatMap { url -> URL? in
                    url.scheme == endpoint.scheme && url.host == endpoint.host && url.port == endpoint.port
                        && url.path.hasPrefix("/media/hud/whip/") ? url : nil
                }
                guard self.generation == run else {
                    if let safe { self.delete(safe, auth: auth) }
                    return
                }
                self.resource = safe
                guard error == nil, http?.statusCode == 201, let safe,
                      let data, let answer = String(data: data, encoding: .utf8) else {
                    self.fail("WHIP publishing failed (HTTP \(http?.statusCode ?? 0)). Check the URL and server status.")
                    return
                }
                self.resource = safe
                self.pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in
                    DispatchQueue.main.async {
                        if self.generation == run, error != nil { self.fail("Invalid WHIP video answer.") }
                    }
                }
            }
        }.resume()
    }
    private func delete(_ url: URL, auth: String) {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"; request.timeoutInterval = 10
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        session.dataTask(with: request).resume()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        DispatchQueue.main.async { if self.pc === peerConnection, newState == .complete { self.publish(self.generation) } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async {
            guard self.pc === peerConnection else { return }
            switch newState {
            case .connected: self.timeout?.cancel(); self.onStatus?("live", nil)
            case .failed: self.fail("WebRTC media connection failed. Check firewall/TURN connectivity.")
            case .disconnected: self.onStatus?("reconnecting", nil); self.armTimeout(self.generation, message: "Media connection was lost.")
            default: break
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

private final class WHIPNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
