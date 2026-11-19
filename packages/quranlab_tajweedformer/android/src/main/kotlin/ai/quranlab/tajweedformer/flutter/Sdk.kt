package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.TajweedBackend
import ai.quranlab.tajweedformer.TajweedChunk
import ai.quranlab.tajweedformer.TajweedDecoded
import ai.quranlab.tajweedformer.TajweedError
import ai.quranlab.tajweedformer.TajweedEvent
import ai.quranlab.tajweedformer.TajweedFrame
import ai.quranlab.tajweedformer.TajweedHead
import ai.quranlab.tajweedformer.TajweedHeads
import ai.quranlab.tajweedformer.TajweedModel
import ai.quranlab.tajweedformer.TajweedToken

/**
 * The SDK's objects read through their public properties only (SDK 4.0, NAMES.md of tajweedformer-sdk-android), handed
 * to [Wire]. Nothing here constructs an SDK type or reaches an internal one.
 */
internal object Sdk {
    fun backend(b: TajweedBackend): BackendMessage = Wire.backend(b.kind, b.name, b.stage, b.reason)

    fun error(e: TajweedError): ErrorMessage = Wire.error(e.code, e.message, e.fix, e.docs)

    fun flutterError(e: TajweedError): FlutterError = Wire.flutterError(e.code, e.message, e.fix, e.docs)

    fun model(m: TajweedModel): ModelMessage = ModelMessage(
        id = m.id,
        version = m.version,
        build = m.build,
        contexts = m.contexts,
        chunkMs = m.contexts.map { m.chunkMs(it).toLong() },
        defaultContext = m.defaultContext,
        tokens = TokensMessage(names = m.tokens.names, blank = m.tokens.blank.toLong(), wordBar = m.tokens.wordBar.toLong()),
        calibration = m.calibration?.let { CalibrationMessage(it.json, it.sha256) },
        hasReference = m.reference != null,
        sampleClips = m.sampleClips.map { ClipMessage(it.name, it.kind, it.durationMs) },
        backend = backend(m.backend),
    )

    fun event(e: TajweedEvent): EventMessage = when (e) {
        is TajweedEvent.SpeechStarted -> EventMessage(type = "speechStarted", atMs = e.atMs)
        is TajweedEvent.SpeechEnded -> EventMessage(type = "speechEnded", atMs = e.atMs, silenceMs = e.silenceMs)
        is TajweedEvent.Interrupted -> EventMessage(type = "interrupted", cause = Wire.cause(e.cause))
        is TajweedEvent.Resumed -> EventMessage(type = "resumed")
        is TajweedEvent.BackendChanged -> EventMessage(type = "backendChanged", backend = backend(e.backend), fromChunk = e.fromChunk.toLong())
        is TajweedEvent.Ended -> EventMessage(type = "ended", reason = Wire.endReason(e.reason), error = e.error?.let { error(it) })
    }

    fun head(h: TajweedHead): HeadMessage = Wire.head(h.name, h.kind, h.frameMs, h.frames, h.classes, h.values, h.classNames)

    fun heads(h: TajweedHeads): List<HeadMessage> = h.names.mapNotNull { n -> h[n]?.let { head(it) } }

    fun tok(t: TajweedToken): Tok = Tok(t.id, t.firstMs, t.peakMs, t.lastMs, t.confidence)

    fun frm(f: TajweedFrame): Frm = Frm(f.index, f.top, f.topLogProb, f.runnerUp, f.margin, f.topK, f.topKLogProbs)

    /** The decoded layer as [Wire] reads it: each token and frame is read when it is asked for. */
    fun dec(d: TajweedDecoded): Dec = Dec(View(d.tokens, ::tok), View(d.frames, ::frm), d.settled, d.isFinal)

    fun chunk(c: TajweedChunk, encoder: DeltaEncoder): ChunkMessage = ChunkMessage(
        index = c.index.toLong(),
        startMs = c.startMs,
        endMs = c.endMs,
        firstFrame = c.firstFrame.toLong(),
        backend = backend(c.backend),
        speech = c.speech,
        heads = heads(c.heads),
        decoded = encoder.decoded(dec(c.decoded), c.firstFrame),
    )

    /** A read-only list of [list] read through [map]. */
    private class View<S, T>(private val list: List<S>, private val map: (S) -> T) : AbstractList<T>() {
        override val size: Int get() = list.size
        override fun get(index: Int): T = map(list[index])
    }
}
