// TajweedFormer for Flutter on iOS: the Dart API's calls on the Apple SDK (Swift package tajweedformer-apple).
//
// Built and run on 2026-11-19 against the Apple SDK 4.0: the iOS Simulator and an iPhone 15 Pro Max, the plugin's
// end-to-end test against production.
//
// The SDK's objects are the process's (one Client per process); they hang on `Host`. Every call answers with the
// SDK's result or with its error as the channel's error (the SDK's code, its message, and [fix, docs]). The SDK
// presents its own sharing sheet over the front view controller (the Flutter view controller), which is its
// documented path for an app that does not use SwiftUI's `.quranLabSharing()`.
import Flutter
import Foundation
import SwiftUI
import TajweedFormer
import UIKit

/// The process's SDK objects, behind one lock: the host API's calls arrive on several tasks at once.
final class Host: @unchecked Sendable {
    static let shared = Host()
    private let lock = NSLock()
    private var _client: TajweedClient?
    private var _key: String?
    private var _model: TajweedModel?
    private var _sessions: [Int64: SessionHost] = [:]
    private var _theme: SharingTheme = .standard

    func with<T>(_ body: (Host) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    var client: TajweedClient? { get { with { $0._client } } }
    var key: String? { get { with { $0._key } } }
    var model: TajweedModel? { get { with { $0._model } } }
    var theme: SharingTheme { get { with { $0._theme } } }

    func set(client: TajweedClient?, key: String?) { with { $0._client = client; $0._key = key } }
    func set(model: TajweedModel?) { with { $0._model = model } }
    func set(theme: SharingTheme) { with { $0._theme = theme } }
    func session(_ id: Int64) -> SessionHost? { with { $0._sessions[id] } }
    func add(_ s: SessionHost) { with { $0._sessions[s.id] = s } }

    /// Removes and returns every session (a hot restart, a closed client or model).
    func takeSessions() -> [SessionHost] {
        with { h in
            let all = Array(h._sessions.values)
            h._sessions.removeAll()
            return all
        }
    }

    /// Removes the sessions whose take has ended (a model has one take at a time).
    func dropEnded() {
        with { h in
            for (id, s) in h._sessions where !s.isOpen {
                s.detach()
                h._sessions.removeValue(forKey: id)
            }
        }
    }
}

/// One take of the Dart side: the SDK's Session and the two streams sent to Dart as they come.
final class SessionHost: @unchecked Sendable {
    let id: Int64
    let session: TajweedSession
    let topK: Int
    private let encoder: DeltaEncoder
    private var collector: Task<Void, Never>?
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    init(id: Int64, session: TajweedSession, topK: Int, emit: @escaping @Sendable (UpdateMessage) -> Void) {
        self.id = id
        self.session = session
        self.topK = topK
        self.encoder = DeltaEncoder(topK: topK)
        let encoder = self.encoder
        collector = Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await c in session.chunks {
                        let m = encoder.chunk(c)
                        emit(ChunkUpdate(sessionId: id, chunk: m))
                    }
                }
                group.addTask {
                    for await e in session.events {
                        emit(EventUpdate(sessionId: id, event: Wire.event(e)))
                    }
                }
            }
            self?.markClosed()
            emit(ClosedUpdate(sessionId: id))
        }
    }

    private func markClosed() {
        lock.lock()
        open = false
        lock.unlock()
    }

    /// Stops sending this take's updates (the plugin is going away); the take itself is cancelled by the caller.
    func detach() {
        collector?.cancel()
    }
}

public final class TajweedFormerPlugin: NSObject, FlutterPlugin, TajweedHostApi {
    private var sink: PigeonEventSink<UpdateMessage>?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = TajweedFormerPlugin()
        TajweedHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
        UpdatesStreamHandler.register(with: registrar.messenger(), streamHandler: Updates(plugin: instance))
        registrar.publish(instance)
    }

    /// The event channel's handler: Dart listens once, before its first take or download.
    final class Updates: UpdatesStreamHandler {
        weak var plugin: TajweedFormerPlugin?
        init(plugin: TajweedFormerPlugin) { self.plugin = plugin }
        override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<UpdateMessage>) { plugin?.sink = sink }
        override func onCancel(withArguments arguments: Any?) { plugin?.sink = nil }
    }

    /// To Dart, on the main thread (an event sink must be called there).
    private func emitter() -> @Sendable (UpdateMessage) -> Void {
        return { [weak self] u in
            DispatchQueue.main.async { self?.sink?.success(u) }
        }
    }

    // ---- errors ----

    /// Runs an SDK call; its failure becomes the channel's error with the SDK's code.
    private func sdk<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as TajweedError {
            throw Wire.pigeonError(e)
        } catch let e as PigeonError {
            throw e
        } catch {
            throw Wire.pluginError("engine_failed", "\(error)", fix: "Send client.diagnose() with an issue to Quran Lab.")
        }
    }

    private func client() throws -> TajweedClient {
        guard let c = Host.shared.client else {
            throw Wire.pluginError("invalid_argument", "client: it is not made yet", fix: "Call TajweedClient.create first.")
        }
        return c
    }

    private func model() throws -> TajweedModel {
        guard let m = Host.shared.model else {
            throw Wire.pluginError("invalid_argument", "model: it is closed", fix: "Call client.model() again.")
        }
        return m
    }

    private func session(_ id: Int64) throws -> SessionHost {
        guard let s = Host.shared.session(id) else {
            throw Wire.pluginError("session_closed", "This take is over.", fix: "Start a new take with model.listen() or model.session().")
        }
        return s
    }

    private func cancelSessions() async {
        for s in Host.shared.takeSessions() {
            s.detach()
            await s.session.cancel()
        }
    }

    // ---- the client ----

    func createClient(key: String, options: ClientOptionsMessage) async throws {
        try await sdk {
            if Host.shared.client != nil {
                guard key == Host.shared.key else {
                    throw Wire.pluginError("client_exists", "A TajweedClient is already open in this process.",
                                           fix: "Keep the one client and reuse it; close it before making one with another key.")
                }
                // the same key again: Dart restarted (a hot restart) or a second engine asks; its takes are gone
                await cancelSessions()
                return
            }
            let o = TajweedClientOptions(
                appId: options.appId,
                appVersion: options.appVersion,
                storage: options.storage.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
            let c = try TajweedClient(key: key, options: o)
            // a theme the app set before the Client: the SDK's own sheet and card take it too (Apple 4.0)
            c.sharing.theme = Host.shared.theme
            Host.shared.set(client: c, key: key)
        }
    }

    func closeClient() async throws {
        try await sdk {
            guard let c = Host.shared.client else { return }
            await cancelSessions()
            if let m = Host.shared.model { await m.close() }
            Host.shared.set(model: nil)
            Host.shared.set(client: nil, key: nil)
            c.close()
        }
    }

    func model(version: String?, progressId: Int64?) async throws -> ModelMessage {
        try await sdk {
            let c = try client()
            if let p = progressId, version == nil {
                try await prefetchWithProgress(c, unmeteredOnly: false, progressId: p)
            }
            let m = try await c.model(version: version)
            Host.shared.set(model: m)
            return await Wire.model(m)
        }
    }

    func prefetch(unmeteredOnly: Bool, progressId: Int64?) async throws {
        try await sdk {
            let c = try client()
            if let p = progressId {
                try await prefetchWithProgress(c, unmeteredOnly: unmeteredOnly, progressId: p)
            } else {
                try await c.prefetch(unmeteredOnly: unmeteredOnly)
            }
        }
    }

    /// The download with its progress sent to Dart at most every 100 ms, and always at the end.
    private func prefetchWithProgress(_ c: TajweedClient, unmeteredOnly: Bool, progressId: Int64) async throws {
        let emit = emitter()
        let throttle = Throttle(seconds: 0.1)
        try await c.prefetch(unmeteredOnly: unmeteredOnly, onProgress: { done, total in
            if throttle.pass(force: done >= total) {
                emit(ProgressUpdate(callId: progressId, done: done, total: total))
            }
        })
    }

    func storage() async throws -> StorageMessage {
        try await sdk {
            let s = try client().storage
            return StorageMessage(
                models: s.models.map { StoredModelMessage(version: $0.version, build: $0.build, bytes: $0.bytes) },
                sharingQueueBytes: s.sharingQueueBytes
            )
        }
    }

    func removeModels() async throws {
        try await sdk {
            let c = try client()
            await cancelSessions()
            if let m = Host.shared.model { await m.close() }
            Host.shared.set(model: nil)
            try c.removeModels()
        }
    }

    func diagnose() async throws -> String {
        try await sdk { try await client().diagnose().json }
    }

    func modelBackend() async throws -> BackendMessage {
        // Apple 4.0: TajweedModel.backend is `get async`
        try await sdk { Wire.backend(try await model().backend) }
    }

    func closeModel() async throws {
        try await sdk {
            guard let m = Host.shared.model else { return }
            await cancelSessions()
            Host.shared.set(model: nil)
            await m.close()
        }
    }

    // ---- takes ----

    func openSession(sessionId: Int64, mode: String, options: SessionOptionsMessage, clipName: String?,
                     samples: FlutterStandardTypedData?, sampleRate: Int64?) async throws {
        try await sdk {
            let m = try model()
            let o = Wire.options(options)
            Host.shared.dropEnded()
            let session: TajweedSession
            switch mode {
            case "listen":
                session = try await m.listen(options: o)
            case "clip":
                guard let clip = m.sampleClips.first(where: { $0.name == clipName }) else {
                    throw Wire.pluginError("invalid_argument", "clip: \(clipName ?? "nil") is not one of model.sampleClips",
                                           fix: "Pass one of model.sampleClips.")
                }
                session = try await m.listen(from: clip, options: o)
            case "samples":
                guard let s = samples else {
                    throw Wire.pluginError("invalid_argument", "samples: none were given", fix: "Pass the samples to listen to.")
                }
                session = try await m.listen(from: Wire.samples(s.data, int16: false), sampleRate: Double(sampleRate ?? 16000), options: o)
            case "push":
                session = try await m.session(options: o)
            default:
                throw Wire.pluginError("invalid_argument", "mode: \(mode) is not listen, clip, samples or push", fix: "Update the plugin.")
            }
            Host.shared.add(SessionHost(id: sessionId, session: session, topK: o.topK, emit: emitter()))
        }
    }

    func push(sessionId: Int64, pcm: FlutterStandardTypedData, int16: Bool) async throws {
        try await sdk {
            // the Dart side sends a take's pushes one after another, so they arrive in order
            try session(sessionId).session.push(Wire.samples(pcm.data, int16: int16))
        }
    }

    func finish(sessionId: Int64) async throws -> HeadsMessage {
        try await sdk {
            let s = try session(sessionId)
            let heads = try await s.session.finish()
            return HeadsMessage(heads: Wire.heads(heads), decoded: Wire.decoded(heads.decoded(), topK: s.topK))
        }
    }

    func cancel(sessionId: Int64) async throws {
        try await sdk {
            guard let s = Host.shared.session(sessionId) else { return }
            await s.session.cancel()
        }
    }

    func sessionBackend(sessionId: Int64) async throws -> BackendMessage {
        try await sdk { try Wire.backend(session(sessionId).session.backend) }
    }

    func reportRecited(sessionId: Int64, surah: Int64, ayahFrom: Int64, ayahTo: Int64, outcome: RecitedOutcomeMessage?,
                       perAyah: [RecitedOutcomeMessage]) async throws {
        try await sdk {
            var per: [Int: TajweedRecitedOutcome] = [:]
            for m in perAyah {
                guard let ayah = m.ayah else {
                    throw Wire.pluginError("invalid_argument", "Invalid argument: perAyah: an entry names no ayah.",
                                           fix: "Name the ayah of every per-ayah outcome.")
                }
                per[Int(ayah)] = Wire.outcome(m)
            }
            try session(sessionId).session.reportRecited(surah: Int(surah), ayahFrom: Int(ayahFrom), ayahTo: Int(ayahTo),
                                                         outcome: outcome.map { Wire.outcome($0) }, perAyah: per)
        }
    }

    // ---- the reference data ----

    private func reference() throws -> TajweedReference {
        guard let r = try model().reference else {
            throw Wire.pluginError("reference_missing", "This model build ships no reference data.",
                                   fix: "Check model.reference before using it.")
        }
        return r
    }

    func referenceIsDownloaded() async throws -> Bool {
        try await sdk { try reference().isDownloaded }
    }

    func referenceFetch() async throws {
        try await sdk { try await reference().fetch() }
    }

    func referenceUnits(surah: Int64, ayah: Int64) async throws -> UnitsMessage {
        try await sdk {
            let r = try reference().units(surah: Int(surah), ayah: Int(ayah))
            return UnitsMessage(units: Wire.int32s(r.units.map { Int32($0) }), wordStarts: Wire.int32s(r.wordStarts.map { Int32($0) }))
        }
    }

    // ---- sharing ----

    func sharingState() async throws -> SharingStateMessage {
        try await sdk {
            let s = try client().sharing
            return SharingStateMessage(available: s.isAvailable, on: s.isOn, recoveryCode: s.recoveryCode)
        }
    }

    func sharingSetOn(on: Bool) async throws {
        try await sdk { try await client().sharing.setOn(on) }
    }

    func sharingAsk() async throws -> Bool {
        try await sdk {
            let s = try client().sharing
            return await MainActor.run { s.ask() }
        }
    }

    func sharingFeed(pcm: FlutterStandardTypedData, int16: Bool, sampleRate: Int64) async throws {
        try await sdk { try client().sharing.feed(Wire.samples(pcm.data, int16: int16), sampleRate: Double(sampleRate)) }
    }

    func sharingItems() async throws -> [SharingItemMessage] {
        try await sdk {
            // Apple 4.0: TajweedSharing.items is `get async`
            try await client().sharing.items.map {
                SharingItemMessage(status: $0.status, day: $0.day, durationMs: Int64($0.durationMs), bytes: $0.bytes)
            }
        }
    }

    func sharingSummary() async throws -> SharingSummaryMessage? {
        try await sdk {
            guard let s = try await client().sharing.summary() else { return nil }
            return SharingSummaryMessage(
                mySessions: Int64(s.mySessions),
                myMinutes: s.myMinutes,
                appContributors: s.appContributors.map { Int64($0) },
                appMinutes: s.appMinutes,
                allContributors: Int64(s.allContributors),
                allMinutes: s.allMinutes,
                line: s.line
            )
        }
    }

    func sharingDelete() async throws -> Bool {
        let c = try client()
        do {
            try await c.sharing.delete()
            return true
        } catch let e as TajweedError {
            // as on Android: the device that cannot read the learner's keys is an error; no connection or a refusal
            // is false (nothing changed, try again)
            if e.code == "storage_failed" { throw Wire.pigeonError(e) }
            return false
        }
    }

    func sharingSetWording(overrides: [String: String]?) async throws {
        try await sdk { try client().sharing.setWording(overrides) }
    }

    func sharingSetTheme(theme: SharingThemeMessage) async throws {
        let base = SharingTheme.standard
        // the sheet's radius is the buttons' times two (the Apple SDK's cornerRadius is the buttons')
        let t = SharingTheme(
            accent: theme.accent.map { Self.color($0) } ?? base.accent,
            background: theme.background.map { Self.color($0) } ?? base.background,
            text: theme.text.map { Self.color($0) } ?? base.text,
            secondaryText: theme.secondaryText.map { Self.color($0) } ?? base.secondaryText,
            cornerRadius: theme.cornerRadius.map { CGFloat($0) / 2 } ?? base.cornerRadius
        )
        Host.shared.set(theme: t)
        // Apple 4.0: `client.sharing.theme` reaches the SDK's own consent sheet and re-ask card, not only the settings
        Host.shared.client?.sharing.theme = t
    }

    private static func color(_ argb: Int64) -> Color {
        let v = UInt32(truncatingIfNeeded: argb)
        return Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255,
                     opacity: Double((v >> 24) & 0xFF) / 255)
    }

    func sharingOpenSettings() async throws {
        let c = try client()
        let theme = Host.shared.theme
        let shown: Bool = await MainActor.run {
            guard let top = Self.topViewController() else { return false }
            let settings = SharingSettingsViewController(c, theme: theme)
            settings.navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak settings] _ in settings?.dismiss(animated: true) })
            let nav = UINavigationController(rootViewController: settings)
            top.present(nav, animated: true)
            return true
        }
        if !shown {
            throw Wire.pluginError("invalid_argument", "activity: the app has no view controller in front",
                                   fix: "Open the settings while the app is in the foreground.")
        }
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
              var top = window.rootViewController else { return nil }
        while let next = top.presentedViewController { top = next }
        return top
    }

    func reportChecks(rule: String, checked: Int64, flagged: Int64) async throws {
        try await sdk { try client().analytics.reportChecks(rule: rule, checked: Int(checked), flagged: Int(flagged)) }
    }
}

/// Lets a call through at most once per interval, and always when forced.
final class Throttle: @unchecked Sendable {
    private let seconds: TimeInterval
    private var last: TimeInterval = -.infinity
    private let lock = NSLock()

    init(seconds: TimeInterval) { self.seconds = seconds }

    func pass(force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if !force && now - last < seconds { return false }
        last = now
        return true
    }
}
