package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.RecitedOutcome
import ai.quranlab.tajweedformer.TajweedBackend
import ai.quranlab.tajweedformer.TajweedEvent
import ai.quranlab.tajweedformer.TajweedHead
import ai.quranlab.tajweedformer.TajweedSessionOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The SDK's values as the messages Dart reads (pigeon/messages.dart), and back. Pure: no Android, no SDK state, and no
 * SDK object either. The SDK's output types have no public constructor, so everything here works on plain values
 * (its public enums, [Tok], [Frm], [Dec]) that [Sdk] reads from the SDK's public properties; the unit tests run it on
 * the JVM.
 */
internal object Wire {
    fun backend(kind: TajweedBackend.Kind, name: String, stage: TajweedBackend.Stage, reason: String?): BackendMessage = BackendMessage(
        kind = if (kind == TajweedBackend.Kind.ACCELERATOR) "accelerator" else "cpu",
        name = name,
        stage = stage.name.lowercase(),
        reason = reason,
    )

    fun error(code: String, message: String, fix: String, docs: String, cause: ErrorCauseMessage? = null): ErrorMessage =
        ErrorMessage(code, message, fix, docs, cause)

    /** The SDK's failure as the platform channel carries it: its code, its message, and [fix, docs, cause] (or null). */
    fun flutterError(code: String, message: String, fix: String, docs: String, cause: ErrorCauseMessage?): FlutterError =
        FlutterError(code, message, listOf(fix, docs, cause))

    /** The public cause of the SDK's error (`TajweedError.errorCause`, contract 24.13), its tokens unchanged. */
    fun errorCause(stage: String, reason: String, httpStatus: Int?, errorName: String?, errorCode: String?,
                   needs: String?): ErrorCauseMessage =
        ErrorCauseMessage(stage, reason, httpStatus?.toLong(), errorName, errorCode, needs)

    fun options(o: SessionOptionsMessage): TajweedSessionOptions = TajweedSessionOptions(
        context = o.context,
        sampleRate = o.sampleRate.toInt(),
        heads = o.heads,
        // coreml-compact is Apple's; on Android it is the default pipeline
        backend = if (o.backend == "cpu") TajweedSessionOptions.Backend.CPU else TajweedSessionOptions.Backend.AUTO,
        topK = o.topK.toInt(),
        endOnSilenceMs = o.endOnSilenceMs?.toInt(),
        pace = if (o.pace == "fast") TajweedSessionOptions.Pace.FAST else TajweedSessionOptions.Pace.REAL_TIME,
    )

    fun endReason(r: TajweedEvent.Ended.Reason): String = when (r) {
        TajweedEvent.Ended.Reason.SILENCE -> "silence"
        TajweedEvent.Ended.Reason.BACKGROUND -> "background"
        TajweedEvent.Ended.Reason.HIDDEN -> "hidden"
        TajweedEvent.Ended.Reason.INTERRUPTED -> "interrupted"
        TajweedEvent.Ended.Reason.SOURCE_END -> "sourceEnd"
        TajweedEvent.Ended.Reason.LIMIT -> "limit"
        TajweedEvent.Ended.Reason.ERROR -> "error"
    }

    fun cause(c: TajweedEvent.Interrupted.Cause): String =
        if (c == TajweedEvent.Interrupted.Cause.ROUTE_CHANGE) "routeChange" else "interruption"

    /**
     * One head. Dart reads class names for an attribute head only (`TajweedHead.classNames`); a CTC head's are the
     * model's tokens, which Dart already has, so they do not travel with every chunk.
     */
    fun head(name: String, kind: TajweedHead.Kind, frameMs: Int, frames: Int, classes: Int, values: FloatArray,
             classNames: List<String>?): HeadMessage = HeadMessage(
        name = name,
        kind = if (kind == TajweedHead.Kind.CTC) "ctc" else "attribute",
        frameMs = frameMs.toLong(),
        frames = frames.toLong(),
        classes = classes.toLong(),
        values = floatBytes(values),
        classNames = if (kind == TajweedHead.Kind.ATTRIBUTE) classNames?.takeIf { it.isNotEmpty() } else null,
    )

    /** float32 values as little-endian bytes (what Dart views as a Float32List). */
    fun floatBytes(v: FloatArray): ByteArray {
        val b = ByteBuffer.allocate(v.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        b.asFloatBuffer().put(v)
        return b.array()
    }

    /** Pushed bytes as the SDK's float samples: float32, or signed 16-bit scaled to -1..1, little endian. */
    fun samples(bytes: ByteArray, int16: Boolean): FloatArray {
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return if (int16) {
            val s = b.asShortBuffer()
            FloatArray(s.remaining()) { s.get(it) / 32768f }
        } else {
            val f = b.asFloatBuffer()
            FloatArray(f.remaining()).also { f.get(it) }
        }
    }

    /**
     * The Client to take when making one failed with [code]: the process's own ([current]) for `client_exists` when the
     * plugin held none ([pluginHeld] false), which a process that WorkManager started made from the app's saved
     * options; else null (the failure stands).
     */
    fun <C> adopt(code: String, pluginHeld: Boolean, current: C?): C? =
        if (code == "client_exists" && !pluginHeld) current else null

    /** The app's judgement of a recited range as the SDK takes it (its checks: `invalid_argument` for a bad one). */
    fun outcome(m: RecitedOutcomeMessage): RecitedOutcome =
        if (m.correct) RecitedOutcome.correct() else RecitedOutcome.incorrect(m.mistakes?.toInt(), m.rules)

    /** The per-ayah outcomes by ayah; null when an entry names no ayah. */
    fun perAyah(list: List<RecitedOutcomeMessage>): Map<Int, RecitedOutcome>? {
        val out = LinkedHashMap<Int, RecitedOutcome>()
        for (m in list) out[(m.ayah ?: return null).toInt()] = outcome(m)
        return out
    }

    /**
     * Where each word of an ayah's [units] starts: the first unit, and the unit after each word bar (the reference has
     * the bar between words, and a bar belongs to the word before it).
     */
    fun wordStarts(units: IntArray, wordBar: Int): IntArray {
        val starts = ArrayList<Int>()
        if (units.isNotEmpty()) starts.add(0)
        for (i in 0 until units.size - 1) if (units[i] == wordBar) starts.add(i + 1)
        return starts.toIntArray()
    }

    /** A whole decoded layer (the one `finish` returns). */
    fun decoded(d: Dec, topK: Int): DecodedMessage = decoded(d.tokens, 0, d.frames, 0, topK, d.settled, d.isFinal)

    fun decoded(tokens: List<Tok>, tokenStart: Int, frames: List<Frm>, frameStart: Int, topK: Int,
                settled: Int, isFinal: Boolean): DecodedMessage {
        val tn = tokens.size - tokenStart
        val fn = frames.size - frameStart
        val tk = IntArray(fn * topK)
        val tkl = DoubleArray(fn * topK)
        val fs = ArrayList<Frm>(fn)
        for (i in 0 until fn) fs.add(frames[frameStart + i])
        val ts = ArrayList<Tok>(tn)
        for (i in 0 until tn) ts.add(tokens[tokenStart + i])
        for (i in 0 until fn) {
            val f = fs[i]
            for (k in 0 until topK) {
                tk[i * topK + k] = f.topK.getOrElse(k) { -1 }
                tkl[i * topK + k] = f.topKLogProbs.getOrNull(k)?.toDouble() ?: Double.NEGATIVE_INFINITY
            }
        }
        return DecodedMessage(
            tokenStart = tokenStart.toLong(),
            tokenIds = IntArray(tn) { ts[it].id },
            tokenFirstMs = IntArray(tn) { ts[it].firstMs.toInt() },
            tokenPeakMs = IntArray(tn) { ts[it].peakMs.toInt() },
            tokenLastMs = IntArray(tn) { ts[it].lastMs.toInt() },
            tokenConfidence = DoubleArray(tn) { ts[it].confidence.toDouble() },
            frameStart = frameStart.toLong(),
            frameTop = IntArray(fn) { fs[it].top },
            frameTopLogProb = DoubleArray(fn) { fs[it].topLogProb.toDouble() },
            frameRunnerUp = IntArray(fn) { fs[it].runnerUp },
            // Android gives the margin, not the runner-up's log-probability: it is the top's minus the margin
            frameRunnerUpLogProb = DoubleArray(fn) { (fs[it].topLogProb - fs[it].margin).toDouble() },
            frameMargin = DoubleArray(fn) { fs[it].margin.toDouble() },
            topK = topK.toLong(),
            frameTopK = tk,
            frameTopKLogProbs = tkl,
            settled = settled.toLong(),
            isFinal = isFinal,
        )
    }
}

/** A token of the decoded layer, as the SDK's `TajweedToken` gives it (equal when the SDK's would be). */
internal data class Tok(val id: Int, val firstMs: Long, val peakMs: Long, val lastMs: Long, val confidence: Float)

/** A 40 ms frame of the decoded layer, as the SDK's `TajweedFrame` gives it. */
internal class Frm(
    val index: Int,
    val top: Int,
    val topLogProb: Float,
    val runnerUp: Int,
    val margin: Float,
    val topK: List<Int>,
    val topKLogProbs: List<Float>,
)

/** A decoded layer: its tokens and frames (read as they are asked for), how many tokens settled, and the end. */
internal class Dec(val tokens: List<Tok>, val frames: List<Frm>, val settled: Int, val isFinal: Boolean)

/**
 * One take's decoded layer as deltas: each chunk sends the tokens from the first one that differs from what Dart
 * holds, and the frames from the chunk's own first frame (the frames before it are the earlier chunks', which a
 * chunk never changes; a replay after a change of backend starts at an earlier frame and replaces from there).
 */
internal class DeltaEncoder(private val topK: Int) {
    private var sentTokens: List<Tok> = emptyList()
    private var sentFrames = 0

    fun decoded(d: Dec, firstFrame: Int): DecodedMessage {
        val tokens = d.tokens
        var t = 0
        val same = minOf(tokens.size, sentTokens.size)
        while (t < same && tokens[t] == sentTokens[t]) t++
        // positions in the list: the take's first frame is its first chunk's (0 for every take the SDK starts)
        val base = d.frames.firstOrNull()?.index ?: 0
        val f = minOf(sentFrames, (firstFrame - base).coerceAtLeast(0), d.frames.size)
        val m = Wire.decoded(tokens, t, d.frames, f, topK, d.settled, d.isFinal)
        sentTokens = ArrayList(tokens)
        sentFrames = d.frames.size
        return m
    }
}

/**
 * The codes the plugin raises itself, before or instead of an SDK call, with the catalogue's words for them (the
 * SDKs' errors.json): the SDK's own errors cross unchanged ([Sdk.flutterError]).
 */
internal object PluginErrors {
    private const val DOCS = "https://sdk.quranlab.ai/docs/errors#"

    fun invalidArgument(detail: String): FlutterError = make("invalid_argument", "Invalid argument: $detail.",
        "Pass a value the API accepts: a context or head name the model lists, a sample rate the SDK can resample, a " +
            "surah from 1 to 114 with ayahs inside it, a rule name of lower-case letters, digits and underscores.")

    fun sessionClosed(): FlutterError = make("session_closed", "The session has ended.",
        "Start a new session with model.listen() or model.session() for the next take.")

    fun referenceMissing(): FlutterError = make("reference_missing", "The reference data is not on this device.",
        "Call model.reference.fetch() once, with a connection, before asking for units.")

    fun runtimeUnsupported(detail: String): FlutterError = make("runtime_unsupported", "The SDK cannot run here: $detail.",
        "Run the app where the SDK is supported: Android 8.0 (API 26) or later, with the plugin attached to a Flutter engine.")

    /** A failure that is not the SDK's TajweedError (the SDK's public calls throw only that): the class, never a message. */
    fun engineFailed(t: Throwable): FlutterError = make("engine_failed", "The engine failed: ${t.javaClass.simpleName}.",
        "Call client.diagnose() and send the report to Quran Lab; a new session on the same model can be tried.")

    /** [fix, docs]: the plugin's own errors carry no cause. */
    private fun make(code: String, message: String, fix: String): FlutterError = FlutterError(code, message, listOf(fix, DOCS + code))
}
