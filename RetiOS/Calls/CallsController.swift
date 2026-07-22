import Foundation
import Observation
import ReticulumSwift
import LXST
#if canImport(AVFAudio)
import AVFAudio
#endif

// MARK: - Call history model

struct CallRecord: Identifiable {
    let id = UUID()
    /// lxst.telephony destination/identity hash hex of the remote party.
    let peerHash: String
    let direction: Direction
    /// When the call attempt started (link establishment began).
    let startTime: Date
    /// When the call ended (nil while active).
    var endTime: Date?
    var outcome: Outcome

    var duration: TimeInterval? {
        guard case .answered = outcome, let end = endTime else { return nil }
        return max(0, end.timeIntervalSince(startTime))
    }

    enum Direction { case outbound, inbound }

    enum Outcome: Equatable {
        case calling            // outbound: link not yet established
        case answered           // link established, audio running
        case missed             // inbound: link closed before user accepted
        case rejected           // inbound: user pressed Decline / remote rejected
        case failed(String)     // error message
    }
}

// MARK: - LXST peer (from mesh announces)

struct LXSTPeer: Identifiable {
    let id: String              // destinationHash hex
    let destinationHash: String
    var lastSeen: Date
}

// MARK: - CallsController

/// Manages the LXST audio call lifecycle.
///
/// As of the C2 interop fix this is a thin coordinator over LXSTSwift's
/// `Telephone`, rather than a hand-rolled link flow. `Telephone` owns the
/// signalling handshake (AVAILABLE → identify → RINGING → CONNECTING →
/// ESTABLISHED), profile negotiation, and the audio pipeline; it talks to the
/// `lxst.telephony` destination — the *same* aspect a Python `rnphone`/LXST node
/// uses — so RetiOS calls now interoperate with Python endpoints. (The previous
/// implementation used a non-standard `lxst.call` aspect and exchanged no
/// signalling, so it could only ever call another copy of itself.)
///
/// This controller maps `Telephone`'s callbacks onto the `@Published` UI state
/// and supplies the platform audio backend + microphone-permission gating.
@MainActor
@Observable
final class CallsController {

    enum CallState: Equatable {
        case idle
        case incoming(Data)        // inbound call ringing; caller's identity hash
        case calling(Data)         // outbound call in progress to this destination hash
        case active(Data, Date)    // connected; peer hash + start time
        case failed(String)
    }

    private(set) var callState: CallState = .idle
    private(set) var isMuted = false
    /// 16-byte hash of our lxst.telephony destination (available after setup).
    private(set) var lxstCallHash: Data?
    /// Whether we actively announce our LXST call address to the mesh.
    private(set) var lxstAnnounceEnabled: Bool = {
        UserDefaults.standard.object(forKey: "lxstAnnounceEnabled") as? Bool ?? false
    }()

    /// Recent calls (most recent first, capped at 100).
    private(set) var callHistory: [CallRecord] = []
    /// LXST-capable peers seen via mesh announces (most recent first).
    private(set) var lxstPeers: [LXSTPeer] = []

    @ObservationIgnored private var transport: Transport?
    @ObservationIgnored private var identity: Identity?
    @ObservationIgnored private var telephone: Telephone?

    /// Display hash for the active/ringing call (dialled hash for outbound,
    /// caller identity hash for inbound). Used to label the call UI.
    @ObservationIgnored private var activePeerHash: Data?
    // In-progress call record — pushed to history when the call ends.
    @ObservationIgnored private var pendingRecord: CallRecord?

    @ObservationIgnored private var lxstAnnounceHandler: LXSTCallAnnounceHandler?
    private static let lxstAnnounceKey = "lxstAnnounceEnabled"

    // MARK: - Setup

    func setup(transport: Transport, identity: Identity) {
        self.transport = transport
        self.identity  = identity

        // Telephone registers its own inbound `lxst.telephony` destination and
        // owns the full call/audio lifecycle. We inject the platform audio
        // backend and bridge its callbacks (which fire off the main thread) to
        // our @MainActor UI state.
        let phone = Telephone(identity: identity, transport: transport)
        phone.makeAudioBackend = { AVAudioEngineBackend() }

        phone.setRingingCallback { [weak self] callerIdentity in
            let hash = callerIdentity?.hash ?? Data()
            Task { @MainActor [weak self] in self?.handleRinging(callerHash: hash) }
        }
        phone.setEstablishedCallback { [weak self] remote in
            let hash = remote?.hash
            Task { @MainActor [weak self] in self?.handleEstablished(remoteHash: hash) }
        }
        phone.setEndedCallback { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleEnded() }
        }
        phone.setBusyCallback { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleBusy() }
        }
        phone.setRejectedCallback { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleRejected() }
        }

        telephone    = phone
        lxstCallHash = phone.destination?.hash

        if lxstAnnounceEnabled { phone.announce() }

        // Track LXST peers from mesh announces (now lxst.telephony, matching the
        // destination Telephone actually serves).
        let handler = LXSTCallAnnounceHandler { [weak self] hex in
            Task { @MainActor [weak self] in self?.receivedLXSTPeer(hex) }
        }
        transport.register(announceHandler: handler)
        lxstAnnounceHandler = handler

        Reticulum.log("CallsController: lxst.telephony destination registered (\(phone.destination?.hash.hexString ?? "?"))",
                      level: .debug)
    }

    // MARK: - LXST peer tracking

    private func receivedLXSTPeer(_ hex: String) {
        let now = Date()
        if let idx = lxstPeers.firstIndex(where: { $0.id == hex }) {
            lxstPeers[idx].lastSeen = now
        } else {
            lxstPeers.insert(LXSTPeer(id: hex, destinationHash: hex, lastSeen: now), at: 0)
        }
        lxstPeers.sort { $0.lastSeen > $1.lastSeen }
        if lxstPeers.count > 200 { lxstPeers = Array(lxstPeers.prefix(200)) }
    }

    // MARK: - Announce

    /// Toggle LXST address announce and persist the choice.
    func setLXSTAnnounce(_ enabled: Bool) {
        lxstAnnounceEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.lxstAnnounceKey)
        if enabled {
            telephone?.announce()
            Reticulum.log("CallsController: announced lxst.telephony", level: .notice)
        }
    }

    /// Send an immediate LXST announce regardless of the persisted toggle state.
    func announceLXSTNow() {
        telephone?.announce()
        Reticulum.log("CallsController: ad-hoc LXST announce sent", level: .notice)
    }

    // MARK: - Path query

    /// Returns `true` if a path to the peer's `lxst.telephony` destination is
    /// known. Pass the peer's **lxmf.delivery** destination hash (16 bytes); the
    /// method derives the corresponding `lxst.telephony` hash internally.
    func hasLXSTCallPath(for lxmfHash: Data) -> Bool {
        guard let transport,
              let identity = Identity.recall(destinationHash: lxmfHash),
              let dest = try? Destination(
                  identity: identity,
                  direction: .out,
                  kind: .single,
                  appName: APP_NAME,
                  aspects: [LXST_TELEPHONY_PRIMITIVE]
              )
        else { return false }
        return transport.hasPath(to: dest.hash)
    }

    // MARK: - Outbound call

    func startCall(to destinationHash: Data) {
        guard let transport, let telephone else { return }
        guard case .idle = callState else { return }

        let hex = destinationHash.hexString

        // Recall the remote identity (stored when their announce arrived).
        guard let remoteIdentity = Identity.recall(destinationHash: destinationHash) else {
            try? transport.requestPath(for: destinationHash)
            failCall("Destination not known — their announce has not been received yet.",
                     hex: hex, direction: .outbound)
            return
        }

        // Verify a path to the lxst.telephony destination exists.
        guard let dest = try? Destination(identity: remoteIdentity, direction: .out,
                                          kind: .single, appName: APP_NAME,
                                          aspects: [LXST_TELEPHONY_PRIMITIVE]) else {
            failCall("Could not build call destination.", hex: hex, direction: .outbound)
            return
        }
        guard transport.hasPath(to: dest.hash) else {
            try? transport.requestPath(for: dest.hash)
            failCall("This peer has not announced their LXST call destination. " +
                     "Ask them to enable LXST on their node so it can announce its call address.",
                     hex: hex, direction: .outbound)
            return
        }

        activePeerHash = destinationHash
        callState = .calling(destinationHash)
        pendingRecord = CallRecord(peerHash: hex, direction: .outbound,
                                   startTime: Date(), outcome: .calling)

        // Audio capture needs mic permission before Telephone opens its pipeline
        // (on ESTABLISHED). Configure the session and request up-front.
        configureAudioSession()
        requestMicPermission { [weak self] granted in
            guard let self, case .calling = self.callState else { return }
            guard granted else {
                self.failCall("Microphone access denied. Allow microphone access in Settings to make calls.",
                              hex: hex, direction: .outbound)
                return
            }
            telephone.call(identity: remoteIdentity)
        }
    }

    // MARK: - Inbound call

    func acceptIncomingCall() {
        guard case .incoming(let callerHash) = callState,
              let telephone,
              let callerIdentity = telephone.activeCall?.remoteIdentity else { return }
        NotificationManager.shared.cancelCallNotification(callerHash: callerHash.hexString)

        configureAudioSession()
        requestMicPermission { [weak self] granted in
            guard let self, case .incoming = self.callState else { return }
            guard granted else {
                self.failCall("Microphone access denied. Allow microphone access in Settings to take calls.",
                              hex: callerHash.hexString, direction: .inbound)
                telephone.hangup()
                return
            }
            telephone.answer(identity: callerIdentity)
        }
    }

    func rejectIncomingCall() {
        guard case .incoming(let callerHash) = callState else { return }
        NotificationManager.shared.cancelCallNotification(callerHash: callerHash.hexString)
        pendingRecord?.outcome = .rejected
        // Telephone sends STATUS_REJECTED to the caller for a ringing incoming call.
        telephone?.hangup()
        // handleTerminated/handleEnded will finalize, but reflect immediately too.
    }

    // MARK: - Shared call controls

    func endCall() {
        // Covers cancelling an outbound call, hanging up an active call, and
        // dismissing a failed-call screen.
        if case .failed = callState {
            finalizePendingRecord(outcome: pendingRecord?.outcome ?? .failed("ended"))
            callState = .idle
            return
        }
        telephone?.hangup()
    }

    func toggleMute() {
        isMuted.toggle()
        if isMuted { telephone?.muteTransmit() } else { telephone?.unmuteTransmit() }
    }

    // MARK: - Telephone callback handlers (main actor)

    private func handleRinging(callerHash: Data) {
        guard case .idle = callState else { return }
        activePeerHash = callerHash
        callState = .incoming(callerHash)

        let callerHex = callerHash.hexString
        pendingRecord = CallRecord(peerHash: callerHex, direction: .inbound,
                                   startTime: Date(), outcome: .missed)
        NotificationManager.shared.scheduleCallNotification(callerHash: callerHex)
        Reticulum.log("CallsController: inbound call from \(callerHex)", level: .notice)
    }

    private func handleEstablished(remoteHash: Data?) {
        let peer = activePeerHash ?? remoteHash ?? Data()
        pendingRecord?.outcome = .answered
        callState = .active(peer, Date())
    }

    private func handleEnded() {
        // Normal teardown: complete an active call, or mark an unanswered
        // inbound call missed / an unconnected outbound call as such.
        let outcome: CallRecord.Outcome
        switch callState {
        case .active:               outcome = .answered
        case .incoming:             outcome = pendingRecord?.outcome ?? .missed
        case .calling:              outcome = .failed("Call could not be connected")
        default:                    outcome = pendingRecord?.outcome ?? .answered
        }
        finalizeAndReset(outcome: outcome)
    }

    private func handleBusy() {
        // Remote signalled BUSY to an outbound attempt.
        if case .incoming = callState { finalizeAndReset(outcome: .missed); return }
        finalizePendingRecord(outcome: .failed("Peer is busy"))
        callState = .failed("Peer is busy")
        isMuted = false
        activePeerHash = nil
    }

    private func handleRejected() {
        // Outbound call declined by the remote (or our own decline echoing back).
        if case .incoming = callState { finalizeAndReset(outcome: .rejected); return }
        finalizePendingRecord(outcome: .rejected)
        callState = .failed("Call was declined")
        isMuted = false
        activePeerHash = nil
    }

    // MARK: - Record helpers

    private func failCall(_ message: String, hex: String, direction: CallRecord.Direction) {
        if pendingRecord == nil {
            pendingRecord = CallRecord(peerHash: hex, direction: direction,
                                       startTime: Date(), outcome: .calling)
        }
        finalizePendingRecord(outcome: .failed(message))
        callState = .failed(message)
        isMuted = false
        activePeerHash = nil
    }

    private func finalizeAndReset(outcome: CallRecord.Outcome) {
        if let hash = activePeerHash {
            NotificationManager.shared.cancelCallNotification(callerHash: hash.hexString)
        }
        finalizePendingRecord(outcome: outcome)
        callState = .idle
        isMuted = false
        activePeerHash = nil
    }

    private func finalizePendingRecord(outcome: CallRecord.Outcome) {
        guard var record = pendingRecord else { return }
        pendingRecord = nil
        record.endTime = Date()
        record.outcome = outcome
        callHistory.insert(record, at: 0)
        if callHistory.count > 100 { callHistory = Array(callHistory.prefix(100)) }
    }

    // MARK: - AVAudioSession / mic permission (iOS)

    /// Request microphone recording permission, calling `completion` on the main actor.
    private func requestMicPermission(completion: @escaping @MainActor (Bool) -> Void) {
        #if os(iOS) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        case .undetermined:
            session.requestRecordPermission { granted in
                Task { @MainActor in completion(granted) }
            }
        @unknown default:
            completion(false)
        }
        #else
        completion(true)
        #endif
    }

    private func configureAudioSession() {
        #if os(iOS) && !targetEnvironment(simulator)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                  mode: .voiceChat,
                                  options: [.allowBluetooth, .defaultToSpeaker])
        try? session.setActive(true)
        #endif
    }
}

// MARK: - LXST announce handler

/// Listens for `lxst.telephony` announces and notifies the controller on the main actor.
/// Traffic is low (LXST announces are rare) so no coalescing is needed.
private final class LXSTCallAnnounceHandler: AnnounceHandler {
    var aspectFilter: String? { "lxst.telephony" }
    private let onAnnounce: @Sendable (String) -> Void

    init(onAnnounce: @escaping @Sendable (String) -> Void) {
        self.onAnnounce = onAnnounce
    }

    func receivedAnnounce(destinationHash: Data, identity: Identity, appData: Data?,
                          announcePacketHash: Data, isPathResponse: Bool) {
        let hex = destinationHash.map { String(format: "%02x", $0) }.joined()
        onAnnounce(hex)
    }
}

// MARK: - Data helpers

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
