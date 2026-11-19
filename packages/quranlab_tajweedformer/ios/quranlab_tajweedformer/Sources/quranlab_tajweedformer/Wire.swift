// The Apple SDK's types as the messages Dart reads (pigeon/messages.dart), and back. The same rules as the
// Android side's Wire.kt: float values as little-endian float32 bytes, the decoded layer as deltas.
//
// Built and run on 2026-11-19 against the Apple SDK 4.0: the iOS Simulator and an iPhone 15 Pro Max, the plugin's
// end-to-end test against production.
import Flutter
import Foundation
import TajweedFormer

enum Wire {
    static func backend(_ b: TajweedBackend) -> BackendMessage {
        BackendMessage(kind: b.kind == .accelerator ? "accelerator" : "cpu", name: b.name, stage: b.stage.rawValue, reason: b.reason)
    }

    static func error(_ e: TajweedError) -> ErrorMessage {
        ErrorMessage(code: e.code, message: e.message, fix: e.fix, docs: e.docs)
    }

    /// A failure as the platform channel carries it: the SDK's code, its message, and [fix, docs].
    static func pigeonError(_ e: TajweedError) -> PigeonError {
        PigeonError(code: e.code, message: e.message, details: [e.fix, e.docs])
    }

    /// An error of the plugin itself, in the catalogue's terms.
    static func pluginError(_ code: String, _ message: String, fix: String) -> PigeonError {
        PigeonError(code: code, message: message, details: [fix, "https://sdk.quranlab.ai/docs/errors#\(code)"])
    }

    /// Apple 4.0: `TajweedModel.backend` is `get async`, so this is too.
    static func model(_ m: TajweedModel) async -> ModelMessage {
        let contexts = m.contexts
        let chunkMs: [Int64] = contexts.map { c in Int64((try? m.chunkMs(c)) ?? 0) }
        let names: [String] = (0..<m.tokens.count).map { m.tokens.name($0) }
        let calibration = m.calibration.map { c in
            CalibrationMessage(json: String(decoding: c.data, as: UTF8.self), sha256: c.sha256)
        }
        return ModelMessage(
            id: m.id,
            version: m.version,
            build: m.build,
            contexts: contexts,
            chunkMs: chunkMs,
            defaultContext: m.defaultContext,
            tokens: TokensMessage(names: names, blank: Int64(m.tokens.blank), wordBar: m.tokens.wordBar.map { Int64($0) }),
            calibration: calibration,
            hasReference: m.reference != nil,
            sampleClips: m.sampleClips.map { ClipMessage(name: $0.name, kind: $0.kind, durationMs: Int64($0.durationMs)) },
            backend: backend(await m.backend)
        )
    }

    /// The app's judgement of a recited range as the Apple SDK takes it (its checks: `invalid_argument`).
    static func outcome(_ m: RecitedOutcomeMessage) -> TajweedRecitedOutcome {
        m.correct ? .correct : .incorrect(mistakes: m.mistakes.map { Int($0) }, rules: m.rules)
    }

    static func options(_ o: SessionOptionsMessage) -> TajweedSessionOptions {
        var heads = TajweedSessionOptions.defaultHeads
        if let h = o.heads {
            heads = (h.count == 1 && h[0] == "all") ? TajweedSessionOptions.allHeads : h
        }
        let backend: TajweedSessionOptions.Backend
        switch o.backend {
        case "cpu": backend = .cpu
        case "coreml-compact": backend = .coremlCompact
        default: backend = .auto
        }
        return TajweedSessionOptions(
            context: o.context,
            sampleRate: Double(o.sampleRate),
            heads: heads,
            backend: backend,
            topK: Int(o.topK),
            endOnSilenceMs: o.endOnSilenceMs.map { Int($0) },
            pace: o.pace == "fast" ? .fast : .realTime
        )
    }

    static func event(_ e: TajweedEvent) -> EventMessage {
        switch e {
        case let .speechStarted(atMs):
            return EventMessage(type: "speechStarted", atMs: Int64(atMs))
        case let .speechEnded(atMs, silenceMs):
            return EventMessage(type: "speechEnded", atMs: Int64(atMs), silenceMs: Int64(silenceMs))
        case let .interrupted(cause):
            return EventMessage(type: "interrupted", cause: cause == .routeChange ? "routeChange" : "interruption")
        case .resumed:
            return EventMessage(type: "resumed")
        case let .backendChanged(backend, fromChunk):
            return EventMessage(type: "backendChanged", backend: Wire.backend(backend), fromChunk: Int64(fromChunk))
        case let .ended(reason):
            switch reason {
            case .silence: return EventMessage(type: "ended", reason: "silence")
            case .background: return EventMessage(type: "ended", reason: "background")
            case .hidden: return EventMessage(type: "ended", reason: "hidden")
            case .interrupted: return EventMessage(type: "ended", reason: "interrupted")
            case .sourceEnd: return EventMessage(type: "ended", reason: "sourceEnd")
            case .limit: return EventMessage(type: "ended", reason: "limit")
            case let .error(err): return EventMessage(type: "ended", reason: "error", error: Wire.error(err))
            }
        @unknown default:
            return EventMessage(type: "resumed")
        }
    }

    static func head(_ h: TajweedHead) -> HeadMessage {
        HeadMessage(
            name: h.name,
            kind: h.kind == .ctc ? "ctc" : "attribute",
            frameMs: Int64(h.frameMs),
            frames: Int64(h.frames),
            classes: Int64(h.classes),
            values: FlutterStandardTypedData(bytes: floatBytes(h.values)),
            classNames: nil
        )
    }

    static func heads(_ h: TajweedHeads) -> [HeadMessage] {
        h.names.compactMap { n in h[n].map { head($0) } }
    }

    /// float32 values as little-endian bytes (every Apple device is little endian).
    static func floatBytes(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Pushed bytes as the SDK's float samples: float32, or signed 16-bit scaled to -1...1, little endian.
    static func samples(_ data: Data, int16: Bool) -> [Float] {
        if int16 {
            let n = data.count / 2
            var out = [Float](repeating: 0, count: n)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<n {
                    let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                    out[i] = Float(s) / 32768
                }
            }
            return out
        }
        let n = data.count / 4
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                out[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
        return out
    }

    static func int32s(_ v: [Int32]) -> FlutterStandardTypedData {
        FlutterStandardTypedData(int32: v.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    static func float64s(_ v: [Double]) -> FlutterStandardTypedData {
        FlutterStandardTypedData(float64: v.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// A whole decoded layer (the one `finish` returns).
    static func decoded(_ d: TajweedDecoded, topK: Int) -> DecodedMessage {
        decoded(tokens: d.tokens, tokenStart: 0, frames: d.frames, frameStart: 0, topK: topK, settled: d.settled, isFinal: d.isFinal)
    }

    static func decoded(tokens: [TajweedToken], tokenStart: Int, frames: [TajweedFrame], frameStart: Int, topK: Int,
                        settled: Int, isFinal: Bool) -> DecodedMessage {
        let t = tokens.count > tokenStart ? Array(tokens[tokenStart...]) : []
        let f = frames.count > frameStart ? Array(frames[frameStart...]) : []
        var tk = [Int32](repeating: -1, count: f.count * topK)
        var tkl = [Double](repeating: -Double.infinity, count: f.count * topK)
        for (i, fr) in f.enumerated() {
            for k in 0..<topK {
                if k < fr.topK.count { tk[i * topK + k] = Int32(fr.topK[k]) }
                if k < fr.topKLogProbs.count { tkl[i * topK + k] = Double(fr.topKLogProbs[k]) }
            }
        }
        return DecodedMessage(
            tokenStart: Int64(tokenStart),
            tokenIds: int32s(t.map { Int32($0.id) }),
            tokenFirstMs: int32s(t.map { Int32($0.firstMs) }),
            tokenPeakMs: int32s(t.map { Int32($0.peakMs) }),
            tokenLastMs: int32s(t.map { Int32($0.lastMs) }),
            tokenConfidence: float64s(t.map { $0.confidence ?? Double.nan }),
            frameStart: Int64(frameStart),
            frameTop: int32s(f.map { Int32($0.top1) }),
            frameTopLogProb: float64s(f.map { Double($0.top1LogProb) }),
            frameRunnerUp: int32s(f.map { Int32($0.runnerUp) }),
            frameRunnerUpLogProb: float64s(f.map { Double($0.runnerUpLogProb) }),
            frameMargin: float64s(f.map { $0.margin }),
            topK: Int64(topK),
            frameTopK: int32s(tk),
            frameTopKLogProbs: float64s(tkl),
            settled: Int64(settled),
            isFinal: isFinal
        )
    }
}

/// One take's decoded layer as deltas (Wire.kt's DeltaEncoder): the tokens from the first one that differs from
/// what Dart holds, the frames from the chunk's own first frame.
final class DeltaEncoder {
    private let topK: Int
    private var sentTokens: [TajweedToken] = []
    private var sentFrames = 0

    init(topK: Int) { self.topK = topK }

    func chunk(_ c: TajweedChunk) -> ChunkMessage {
        ChunkMessage(
            index: Int64(c.index),
            startMs: Int64(c.startMs),
            endMs: Int64(c.endMs),
            firstFrame: Int64(c.firstFrame),
            backend: Wire.backend(c.backend),
            speech: c.speech,
            heads: Wire.heads(c.heads),
            decoded: decoded(c.decoded, firstFrame: c.firstFrame)
        )
    }

    func decoded(_ d: TajweedDecoded, firstFrame: Int) -> DecodedMessage {
        let tokens = d.tokens
        var t = 0
        let same = min(tokens.count, sentTokens.count)
        while t < same && tokens[t] == sentTokens[t] { t += 1 }
        // Apple's frames carry no index: the list's position is the frame's index in the take
        let f = min(sentFrames, max(0, firstFrame), d.frames.count)
        let m = Wire.decoded(tokens: tokens, tokenStart: t, frames: d.frames, frameStart: f, topK: topK,
                             settled: d.settled, isFinal: d.isFinal)
        sentTokens = tokens
        sentFrames = d.frames.count
        return m
    }
}
