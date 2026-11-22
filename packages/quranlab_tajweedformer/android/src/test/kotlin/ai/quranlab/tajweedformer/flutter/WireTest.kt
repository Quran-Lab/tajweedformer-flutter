package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.RecitedOutcome
import ai.quranlab.tajweedformer.TajweedBackend
import ai.quranlab.tajweedformer.TajweedError
import ai.quranlab.tajweedformer.TajweedEvent
import ai.quranlab.tajweedformer.TajweedHead
import ai.quranlab.tajweedformer.TajweedSessionOptions
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The plugin's own logic on the JVM, against the Android SDK 4.0's public API only: its enums, its option and outcome
 * types (which have public constructors), and plain values where the SDK's output types have none.
 */
class WireTest {
    private fun token(id: Int, first: Long, last: Long, conf: Float = 0.9f) = Tok(id, first, (first + last) / 2, last, conf)

    private fun frame(i: Int, top: Int = 3, lp: Float = -0.1f, runnerUp: Int = 0, margin: Float = 2f,
                      topK: List<Int> = emptyList(), topKLp: List<Float> = emptyList()) =
        Frm(i, top, lp, runnerUp, margin, topK, topKLp)

    private fun decoded(tokens: List<Tok>, frames: Int, settled: Int = tokens.size, final: Boolean = false, from: Int = 0) =
        Dec(tokens, (from until frames).map { frame(it) }, settled, final)

    /** The catalogue every SDK shares (sdk_3.0.0/errors.json), in its order. */
    private val catalogue = listOf(
        "invalid_argument", "invalid_key", "sdk_too_old", "server_rejected", "client_exists", "model_unavailable",
        "needs_connection", "network_not_permitted", "download_failed", "storage_full", "storage_failed", "model_missing",
        "model_invalid", "signature_invalid", "checksum_mismatch", "model_incompatible", "runtime_unsupported",
        "reference_missing", "session_open", "session_closed", "cancelled", "engine_failed", "microphone_denied",
        "microphone_unavailable", "interrupted", "sharing_unavailable",
    )

    @Test
    fun floatSamplesAreLittleEndianFloat32() {
        val b = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
        b.putFloat(0.5f).putFloat(-1f).putFloat(0.25f)
        assertContentEquals(floatArrayOf(0.5f, -1f, 0.25f), Wire.samples(b.array(), int16 = false))
    }

    @Test
    fun int16SamplesAreScaledToMinusOneToOne() {
        val b = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
        b.putShort(Short.MIN_VALUE).putShort(0).putShort(16384).putShort(Short.MAX_VALUE)
        val f = Wire.samples(b.array(), int16 = true)
        assertContentEquals(floatArrayOf(-1f, 0f, 0.5f, 32767f / 32768f), f)
    }

    @Test
    fun headValuesRoundTripAsLittleEndianBytes() {
        val v = floatArrayOf(-3.5f, 0f, 1e-7f, Float.NEGATIVE_INFINITY)
        val m = Wire.head("log_probs", TajweedHead.Kind.CTC, 40, 2, 2, v, listOf("<blk>", "a"))
        assertEquals("ctc", m.kind)
        assertEquals(2L, m.frames)
        // a CTC head's class names are the model's tokens, which Dart has: they do not travel with every chunk
        assertNull(m.classNames)
        val back = FloatArray(4)
        ByteBuffer.wrap(m.values).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer().get(back)
        assertContentEquals(v, back)
        val gem = Wire.head("gem", TajweedHead.Kind.ATTRIBUTE, 20, 1, 2, floatArrayOf(0.25f, 0.75f), listOf("single", "held"))
        assertEquals("attribute", gem.kind)
        assertEquals(listOf("single", "held"), gem.classNames)
    }

    @Test
    fun sessionOptionsMapOntoTheSdk() {
        val o = Wire.options(SessionOptionsMessage(context = "c8_l64", sampleRate = 48000, heads = listOf("all"), backend = "cpu",
            topK = 5, endOnSilenceMs = 1500, pace = "fast"))
        assertEquals("c8_l64", o.context)
        assertEquals(48000, o.sampleRate)
        assertEquals(listOf("all"), o.heads)
        assertEquals(TajweedSessionOptions.Backend.CPU, o.backend)
        assertEquals(5, o.topK)
        assertEquals(1500, o.endOnSilenceMs)
        assertEquals(TajweedSessionOptions.Pace.FAST, o.pace)
        // Apple's compact build is the default pipeline on Android
        val c = Wire.options(SessionOptionsMessage(sampleRate = 16000, backend = "coreml-compact", topK = 0, pace = "realTime"))
        assertEquals(TajweedSessionOptions.Backend.AUTO, c.backend)
        assertEquals(TajweedSessionOptions.Pace.REAL_TIME, c.pace)
        assertNull(c.heads)
    }

    @Test
    fun everyEventValueHasItsName() {
        assertEquals(BackendMessage("cpu", "cpu", "demoted", "failover"),
            Wire.backend(TajweedBackend.Kind.CPU, "cpu", TajweedBackend.Stage.DEMOTED, "failover"))
        assertEquals("accelerator", Wire.backend(TajweedBackend.Kind.ACCELERATOR, "npu", TajweedBackend.Stage.PROMOTED, null).kind)
        // every stage of the SDK is one Dart knows (TajweedBackendStage)
        val dart = setOf("cpu", "downloading", "compiling", "testing", "promoted", "demoted")
        for (s in TajweedBackend.Stage.entries) assertTrue(Wire.backend(TajweedBackend.Kind.CPU, "cpu", s, null).stage in dart, "$s")
        assertEquals("routeChange", Wire.cause(TajweedEvent.Interrupted.Cause.ROUTE_CHANGE))
        assertEquals("interruption", Wire.cause(TajweedEvent.Interrupted.Cause.INTERRUPTION))
        val names = TajweedEvent.Ended.Reason.entries.map { Wire.endReason(it) }
        assertEquals(listOf("silence", "background", "hidden", "interrupted", "sourceEnd", "limit", "error"), names)
    }

    @Test
    fun everyCatalogueCodeCrossesUnchanged() {
        // ERRORS_40 24.4: the catalogue is the same 26 codes; the plugin passes the SDK's code, message, fix and docs
        assertEquals(26, catalogue.size)
        for (code in catalogue) {
            val e = Wire.flutterError(code, "m $code", "f $code", "https://sdk.quranlab.ai/docs/errors#$code", null)
            assertEquals(code, e.code)
            assertEquals("m $code", e.message)
            assertEquals(listOf("f $code", "https://sdk.quranlab.ai/docs/errors#$code", null), e.details)
            assertEquals(ErrorMessage(code, "m $code", "f $code", "https://sdk.quranlab.ai/docs/errors#$code"),
                Wire.error(code, "m $code", "f $code", "https://sdk.quranlab.ai/docs/errors#$code"))
        }
    }

    @Test
    fun theErrorsCauseCrossesWithItsTokens() {
        // ERRORS_40 24.13 (errors_40.json causes): the cause the SDK's error carries, unchanged, on both paths
        val model = Wire.errorCause("download", "network", null, "java.net.UnknownHostException", null, "model")
        assertEquals(ErrorCauseMessage("download", "network", null, "java.net.UnknownHostException", null, "model"), model)
        val e = Wire.flutterError("needs_connection", "m", "f", "https://sdk.quranlab.ai/docs/errors#needs_connection", model)
        assertEquals(listOf("f", "https://sdk.quranlab.ai/docs/errors#needs_connection", model), e.details)
        val lease = Wire.errorCause("lease", "network", null, null, null, "lease")
        assertEquals("lease", Wire.error("needs_connection", "m", "f", "d", lease).cause?.needs)
        val limit = Wire.errorCause("download", "rate_limited", 429, null, "model_limit", null)
        assertEquals(429L, limit.httpStatus)
        assertEquals("model_limit", limit.errorCode)
        assertNull(limit.needs)
        // no cause (the five API-misuse codes): null in its place
        assertEquals(listOf("f", "d", null), Wire.flutterError("session_open", "m", "f", "d", null).details)
        assertNull(Wire.error("session_open", "m", "f", "d").cause)
    }

    @Test
    fun theCauseSurvivesTheChannelsCodec() {
        // the error reply as the host API sends it ([code, message, details]), through the codec Dart decodes with
        val cause = Wire.errorCause("lease", "network", null, "java.net.SocketTimeoutException", null, "lease")
        val e = Wire.flutterError("needs_connection", "m", "f", "d", cause)
        val sent = listOf(e.code, e.message, e.details)
        val bytes = TajweedHostApi.codec.encodeMessage(sent)!!
        bytes.rewind()
        assertEquals(sent, TajweedHostApi.codec.decodeMessage(bytes))
        val ended = Wire.error("needs_connection", "m", "f", "d", cause)
        val again = TajweedHostApi.codec.encodeMessage(ended)!!
        again.rewind()
        assertEquals(ended, TajweedHostApi.codec.decodeMessage(again))
    }

    @Test
    fun thePluginsOwnErrorsAreCatalogueCodesWithFixAndDocs() {
        val own = listOf(PluginErrors.invalidArgument("client: it is not made yet"), PluginErrors.sessionClosed(),
            PluginErrors.referenceMissing(), PluginErrors.runtimeUnsupported("no engine"), PluginErrors.engineFailed(IllegalStateException("x")))
        for (e in own) {
            assertTrue(e.code in catalogue, e.code)
            val details = e.details as List<*>
            assertEquals(2, details.size)
            assertTrue((details[0] as String).isNotEmpty())
            assertEquals("https://sdk.quranlab.ai/docs/errors#${e.code}", details[1])
        }
        // a failure that is not the SDK's names its class, never its message (which may carry a path)
        assertEquals("The engine failed: IllegalStateException.", PluginErrors.engineFailed(IllegalStateException("/data/x")).message)
        assertEquals("Invalid argument: client: it is not made yet.", own[0].message)
    }

    @Test
    fun recitedOutcomesGoToTheSdksOwnTypes() {
        assertEquals(RecitedOutcome.correct(), Wire.outcome(RecitedOutcomeMessage(correct = true, rules = emptyList())))
        assertEquals(RecitedOutcome.incorrect(2, listOf("madd", "qalqalah")),
            Wire.outcome(RecitedOutcomeMessage(correct = false, mistakes = 2, rules = listOf("madd", "qalqalah"))))
        assertEquals(RecitedOutcome.incorrect(), Wire.outcome(RecitedOutcomeMessage(correct = false, rules = emptyList())))
        val per = Wire.perAyah(listOf(RecitedOutcomeMessage(correct = true, rules = emptyList(), ayah = 3),
            RecitedOutcomeMessage(correct = false, mistakes = 1, rules = listOf("madd"), ayah = 4)))
        assertEquals(mapOf(3 to RecitedOutcome.correct(), 4 to RecitedOutcome.incorrect(1, listOf("madd"))), per)
        assertEquals(emptyMap(), Wire.perAyah(emptyList()))
        assertNull(Wire.perAyah(listOf(RecitedOutcomeMessage(correct = true, rules = emptyList()))))
        // the SDK's own checks: 0 mistakes, a bad rule id
        assertEquals("invalid_argument", assertFailsWith<TajweedError> {
            Wire.outcome(RecitedOutcomeMessage(correct = false, mistakes = 0, rules = emptyList()))
        }.code)
        assertEquals("invalid_argument", assertFailsWith<TajweedError> {
            Wire.outcome(RecitedOutcomeMessage(correct = false, rules = listOf("Madd")))
        }.code)
    }

    @Test
    fun wordsStartAfterEachWordBar() {
        val bar = 3
        assertContentEquals(intArrayOf(0, 3, 5), Wire.wordStarts(intArrayOf(5, 9, bar, 7, bar, 11, 12), bar))
        assertContentEquals(intArrayOf(0), Wire.wordStarts(intArrayOf(5, 9), bar))
        assertContentEquals(intArrayOf(), Wire.wordStarts(intArrayOf(), bar))
        // a bar at the end starts no word
        assertContentEquals(intArrayOf(0), Wire.wordStarts(intArrayOf(5, bar), bar))
    }

    @Test
    fun theRunnerUpsLogProbIsTheTopsMinusTheMargin() {
        val d = Dec(emptyList(), listOf(frame(0, lp = -0.5f, margin = 1.25f, topK = listOf(3, 0), topKLp = listOf(-0.5f, -1.75f))), 0, false)
        val m = Wire.decoded(d, topK = 2)
        assertEquals(-1.75, m.frameRunnerUpLogProb[0], 1e-6)
        assertContentEquals(intArrayOf(3, 0), m.frameTopK)
        assertEquals(2L, m.topK)
        // a frame with fewer ranked tokens than K is padded, never shifted
        val short = Wire.decoded(Dec(emptyList(), listOf(frame(0, topK = listOf(3), topKLp = listOf(-0.1f))), 0, false), topK = 2)
        assertContentEquals(intArrayOf(3, -1), short.frameTopK)
        assertEquals(Double.NEGATIVE_INFINITY, short.frameTopKLogProbs[1])
    }

    @Test
    fun aChunkSendsOnlyWhatChanged() {
        val enc = DeltaEncoder(0)
        val a = token(5, 0, 80)
        val b = token(9, 120, 160)
        val first = enc.decoded(decoded(listOf(a, b), frames = 8, settled = 1), firstFrame = 0)
        assertEquals(0L, first.tokenStart)
        assertContentEquals(intArrayOf(5, 9), first.tokenIds)
        assertEquals(0L, first.frameStart)
        assertEquals(8, first.frameTop.size)

        // the tail token grew; the settled one did not change: only the tail and the new frames travel
        val b2 = token(9, 120, 200)
        val c = token(11, 280, 300)
        val second = enc.decoded(decoded(listOf(a, b2, c), frames = 16, settled = 2), firstFrame = 8)
        assertEquals(1L, second.tokenStart)
        assertContentEquals(intArrayOf(9, 11), second.tokenIds)
        assertContentEquals(intArrayOf(200, 300), second.tokenLastMs)
        assertEquals(8L, second.frameStart)
        assertEquals(8, second.frameTop.size)

        // nothing new in the tokens: an empty delta from the end
        val third = enc.decoded(decoded(listOf(a, b2, c), frames = 24, settled = 3, final = true), firstFrame = 16)
        assertEquals(3L, third.tokenStart)
        assertEquals(0, third.tokenIds.size)
        assertTrue(third.isFinal)
        assertEquals(3L, third.settled)
    }

    @Test
    fun aReplayAfterAChangeOfBackendStartsAgainAtItsChunk() {
        val enc = DeltaEncoder(0)
        val a = token(5, 0, 80)
        val b = token(9, 120, 160)
        enc.decoded(decoded(listOf(a, b), frames = 16), firstFrame = 8)
        // the CPU replays from the chunk at frame 8: the tokens after `a` differ, the frames from 8 are sent again
        val replay = enc.decoded(decoded(listOf(a, token(7, 130, 150)), frames = 16, settled = 1), firstFrame = 8)
        assertEquals(1L, replay.tokenStart)
        assertContentEquals(intArrayOf(7), replay.tokenIds)
        assertEquals(8L, replay.frameStart)
        assertEquals(8, replay.frameTop.size)
    }

    @Test
    fun theSettingsCardTakesTheThemesBackgroundElseTheDesigns() {
        assertEquals(0xFFFFFFFF.toInt(), SettingsCard.background(ai.quranlab.tajweedformer.SharingTheme(), night = false))
        assertEquals(0xFF1C1C1E.toInt(), SettingsCard.background(ai.quranlab.tajweedformer.SharingTheme(), night = true))
        assertEquals(0xFF1C1C1E.toInt(), SettingsCard.background(ai.quranlab.tajweedformer.SharingTheme(dark = true), night = false))
        assertEquals(0xFF102030.toInt(), SettingsCard.background(ai.quranlab.tajweedformer.SharingTheme(background = 0xFF102030.toInt()), night = true))
    }

    @Test
    fun aClientThatAWorkerMadeIsTakenOnlyWhenThePluginHeldNone() {
        val worker = Any()
        assertTrue(Wire.adopt("client_exists", pluginHeld = false, current = worker) === worker)
        // the plugin's own Client under another key: the SDK's client_exists stands
        assertNull(Wire.adopt("client_exists", pluginHeld = true, current = worker))
        assertNull(Wire.adopt<Any>("client_exists", pluginHeld = false, current = null))
        assertNull(Wire.adopt("invalid_argument", pluginHeld = false, current = worker))
    }

    @Test
    fun theThrottleLetsTheLastProgressThrough() {
        var now = 0L
        val t = Throttle(100) { now }
        assertTrue(t.pass(false))
        now = 50
        assertFalse(t.pass(false))
        assertTrue(t.pass(true))
        now = 120
        assertFalse(t.pass(false))
        now = 151
        assertTrue(t.pass(false))
    }
}
