package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.SharingTheme
import ai.quranlab.tajweedformer.TajweedClient
import ai.quranlab.tajweedformer.TajweedClientOptions
import ai.quranlab.tajweedformer.TajweedError
import ai.quranlab.tajweedformer.TajweedModel
import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * TajweedFormer for Flutter on Android: the Dart API's calls on the Android SDK 4.0 (`ai.quranlab:tajweedformer`),
 * through its public API only.
 *
 * The SDK's objects are the process's (one Client per process); the plugin keeps them in [Host]. Every call answers
 * with the SDK's result or with its error as the channel's error (the SDK's code, message, and [fix, docs]). The SDK
 * shows its own sharing sheets and asks for the microphone itself: since 4.0 it finds the activity in front also when
 * the Client is made after that activity resumed, which is how a Flutter app makes it, and counts that opening.
 */
class TajweedFormerPlugin : FlutterPlugin, ActivityAware, TajweedHostApi {
    private var context: Context? = null
    private var sink: PigeonEventSink<UpdateMessage>? = null
    @Volatile private var activity: Activity? = null

    /** What every SDK object of the process hangs on: shared by the plugin's instances (one per engine). */
    internal object Host {
        @Volatile var client: TajweedClient? = null
        @Volatile var key: String? = null
        @Volatile var model: TajweedModel? = null
        val sessions = ConcurrentHashMap<Long, SessionHost>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

        /** Every take ends (a hot restart, a closed client): the Dart objects that owned them are gone. */
        fun cancelSessions() {
            for (s in sessions.values) {
                s.detach()
                try { s.session.cancel() } catch (_: Exception) {}
            }
            sessions.clear()
        }
    }

    // ---- the engine and the activity ----

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        TajweedHostApi.setUp(b.binaryMessenger, this)
        UpdatesStreamHandler.register(b.binaryMessenger, object : UpdatesStreamHandler() {
            override fun onListen(p0: Any?, sink: PigeonEventSink<UpdateMessage>) { this@TajweedFormerPlugin.sink = sink }
            override fun onCancel(p0: Any?) { this@TajweedFormerPlugin.sink = null }
        })
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        TajweedHostApi.setUp(b.binaryMessenger, null)
        sink = null
        context = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) { activity = b.activity }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)

    override fun onDetachedFromActivity() { activity = null }

    /** To Dart, on the main thread. A take's updates before Dart listens are lost: Dart listens before it opens one. */
    private fun emit(u: UpdateMessage) {
        sink?.success(u)
    }

    // ---- errors ----

    /** Runs an SDK call; its failure becomes the channel's error with the SDK's code. */
    private suspend fun <T> sdk(body: suspend () -> T): T = try {
        body()
    } catch (e: CancellationException) {
        throw e
    } catch (e: FlutterError) {
        throw e
    } catch (e: TajweedError) {
        throw Sdk.flutterError(e)
    } catch (e: Throwable) {
        throw PluginErrors.engineFailed(e)
    }

    private fun client(): TajweedClient = Host.client ?: throw PluginErrors.invalidArgument("client: it is not made yet: call TajweedClient.create first")

    private fun model(): TajweedModel = Host.model ?: throw PluginErrors.invalidArgument("model: it is closed: call client.model() again")

    private fun session(id: Long): SessionHost = Host.sessions[id] ?: throw PluginErrors.sessionClosed()

    // ---- the client ----

    override suspend fun createClient(key: String, options: ClientOptionsMessage) = sdk {
        if (Host.client != null && key == Host.key) {
            // the same key again: Dart restarted (a hot restart) or a second engine asks; its takes are gone
            Host.cancelSessions()
            return@sdk
        }
        // Another key while the plugin's Client is open is the SDK's own client_exists. The activity, when there is
        // one, is the context: the SDK takes it as the activity in front (and keeps the application context), and
        // counts the app's opening, which started before Dart made the Client.
        val ctx = activity ?: context ?: throw PluginErrors.runtimeUnsupported("the plugin is not attached to an engine")
        val held = Host.client != null
        val c = withContext(Dispatchers.IO) {
            try {
                TajweedClient(ctx, key, TajweedClientOptions(
                    appId = options.appId,
                    appVersion = options.appVersion,
                    storage = options.storage?.let { File(it) },
                ))
            } catch (e: TajweedError) {
                // A process that WorkManager started (a delivery, the sharing outbox, a model download) already holds
                // the Client the SDK made from the app's saved options: the app's own, so Dart takes it
                Wire.adopt(e.code, held, TajweedClient.current) ?: throw e
            }
        }
        Host.client = c
        Host.key = key
    }

    override suspend fun closeClient() = sdk {
        val c = Host.client ?: return@sdk
        Host.cancelSessions()
        Host.model = null
        Host.client = null
        Host.key = null
        withContext(Dispatchers.IO) { c.close() }
    }

    override suspend fun model(version: String?, progressId: Long?): ModelMessage = sdk {
        val c = client()
        if (progressId != null && version == null) prefetchWithProgress(c, false, progressId)
        val m = c.model(version)
        Host.model = m
        withContext(Dispatchers.Default) { Sdk.model(m) }
    }

    override suspend fun prefetch(unmeteredOnly: Boolean, progressId: Long?) = sdk {
        val c = client()
        if (progressId == null) c.prefetch(unmeteredOnly) else prefetchWithProgress(c, unmeteredOnly, progressId)
    }

    /** The download with its progress sent to Dart at most every 100 ms, and always at the end. */
    private suspend fun prefetchWithProgress(c: TajweedClient, unmeteredOnly: Boolean, progressId: Long) {
        val throttle = Throttle(100)
        c.prefetch(unmeteredOnly) { done, total ->
            if (throttle.pass(done >= total)) {
                Host.scope.launch(Dispatchers.Main) { emit(ProgressUpdate(progressId, done, total)) }
            }
        }
    }

    override suspend fun storage(): StorageMessage = sdk {
        val s = withContext(Dispatchers.IO) { client().storage }
        @Suppress("UNCHECKED_CAST")
        val models = (s["models"] as? List<Map<String, Any?>>).orEmpty().map {
            StoredModelMessage(it["version"] as? String ?: "", it["build"] as? String ?: "", (it["bytes"] as? Number)?.toLong() ?: 0)
        }
        StorageMessage(models, (s["sharingQueueBytes"] as? Number)?.toLong() ?: 0)
    }

    override suspend fun removeModels() = sdk {
        Host.cancelSessions()
        client().removeModels()
        Host.model = null
    }

    override suspend fun diagnose(): String = sdk { client().diagnose().toJson() }

    override suspend fun modelBackend(): BackendMessage = sdk { Sdk.backend(model().backend) }

    override suspend fun closeModel() = sdk {
        val m = Host.model ?: return@sdk
        Host.cancelSessions()
        Host.model = null
        withContext(Dispatchers.IO) { m.close() }
    }

    // ---- takes ----

    override suspend fun openSession(sessionId: Long, mode: String, options: SessionOptionsMessage, clipName: String?,
                                     samples: ByteArray?, sampleRate: Long?) = sdk {
        val m = model()
        val o = Wire.options(options)
        // a Model has one take at a time: what is left of an ended one goes (its heads were the app's to fetch)
        for ((id, s) in Host.sessions) if (!s.open) { s.detach(); Host.sessions.remove(id) }
        val session = when (mode) {
            // the SDK asks for the microphone itself, over the activity in front
            "listen" -> m.listen(o)
            "clip" -> {
                val clip = m.sampleClips.firstOrNull { it.name == clipName }
                    ?: throw PluginErrors.invalidArgument("clip: $clipName is not one of model.sampleClips")
                m.listen(clip, o)
            }
            "samples" -> {
                val bytes = samples ?: throw PluginErrors.invalidArgument("samples: none were given")
                m.listen(Wire.samples(bytes, int16 = false), (sampleRate ?: 16000L).toInt(), o)
            }
            "push" -> m.session(o)
            else -> throw PluginErrors.invalidArgument("mode: $mode is not listen, clip, samples or push")
        }
        Host.sessions[sessionId] = SessionHost(sessionId, session, o.topK, Host.scope, Dispatchers.Default, Dispatchers.Main,
            emit = ::emit, onOver = {})
    }

    override suspend fun push(sessionId: Long, pcm: ByteArray, int16: Boolean) = sdk {
        session(sessionId).push(Wire.samples(pcm, int16))
    }

    override suspend fun finish(sessionId: Long): HeadsMessage = sdk {
        val s = session(sessionId)
        val heads = s.session.finish()
        withContext(Dispatchers.Default) { HeadsMessage(Sdk.heads(heads), Wire.decoded(Sdk.dec(heads.decoded()), s.topK)) }
    }

    override suspend fun cancel(sessionId: Long) = sdk {
        val s = Host.sessions[sessionId] ?: return@sdk
        s.session.cancel()
    }

    override suspend fun sessionBackend(sessionId: Long): BackendMessage = sdk { Sdk.backend(session(sessionId).session.backend) }

    override suspend fun reportRecited(sessionId: Long, surah: Long, ayahFrom: Long, ayahTo: Long, outcome: RecitedOutcomeMessage?,
                                       perAyah: List<RecitedOutcomeMessage>) = sdk {
        val s = session(sessionId)
        val per = Wire.perAyah(perAyah) ?: throw PluginErrors.invalidArgument("perAyah: an entry names no ayah")
        s.session.reportRecited(surah.toInt(), ayahFrom.toInt(), ayahTo.toInt(), outcome?.let { Wire.outcome(it) }, per)
    }

    // ---- the reference data ----

    private fun reference() = model().reference ?: throw PluginErrors.referenceMissing()

    override suspend fun referenceIsDownloaded(): Boolean = sdk { reference().isDownloaded }

    override suspend fun referenceFetch() = sdk { reference().fetch() }

    override suspend fun referenceUnits(surah: Long, ayah: Long): UnitsMessage = sdk {
        val r = reference()
        val units = withContext(Dispatchers.IO) { r.units(surah.toInt(), ayah.toInt()) }
        UnitsMessage(units, Wire.wordStarts(units, model().tokens.wordBar))
    }

    // ---- sharing ----

    override suspend fun sharingState(): SharingStateMessage = sdk {
        val s = client().sharing
        withContext(Dispatchers.IO) { SharingStateMessage(s.isAvailable, s.isOn, s.recoveryCode) }
    }

    override suspend fun sharingSetOn(on: Boolean) = sdk {
        val s = client().sharing
        // the SDK's switch returns within three seconds, also when a request hangs: off the main thread
        withContext(Dispatchers.IO) { s.setOn(on) }
    }

    /** The SDK's own rules decide (4.0): false when no ask is due or sharing is not offered. */
    override suspend fun sharingAsk(): Boolean = sdk { client().sharing.ask() }

    override suspend fun sharingFeed(pcm: ByteArray, int16: Boolean, sampleRate: Long) = sdk {
        client().sharing.feed(Wire.samples(pcm, int16), sampleRate.toInt())
    }

    override suspend fun sharingItems(): List<SharingItemMessage> = sdk {
        withContext(Dispatchers.IO) { client().sharing.items }.map {
            SharingItemMessage(it["status"] as? String ?: "queued", it["day"] as? String ?: "",
                (it["durationMs"] as? Number)?.toLong() ?: 0, (it["bytes"] as? Number)?.toLong() ?: 0)
        }
    }

    override suspend fun sharingSummary(): SharingSummaryMessage? = sdk {
        val m = client().sharing.summary() ?: return@sdk null
        fun part(k: String) = m[k] as? Map<*, *>
        val you = part("you")
        val app = part("app")
        val all = part("all")
        SharingSummaryMessage(
            mySessions = (you?.get("sessions") as? Number)?.toLong() ?: 0,
            myMinutes = (you?.get("minutes") as? Number)?.toDouble() ?: 0.0,
            appContributors = (app?.get("contributors") as? Number)?.toLong(),
            appMinutes = (app?.get("minutes") as? Number)?.toDouble(),
            allContributors = (all?.get("contributors") as? Number)?.toLong() ?: 0,
            allMinutes = (all?.get("minutes") as? Number)?.toDouble() ?: 0.0,
            line = null,
        )
    }

    override suspend fun sharingDelete(): Boolean = sdk { client().sharing.delete() }

    override suspend fun sharingSetWording(overrides: Map<String, String>?) = sdk { client().sharing.setWording(overrides) }

    override suspend fun sharingSetTheme(theme: SharingThemeMessage) = sdk {
        SharingTheme.current = SharingTheme(
            background = theme.background?.toInt(),
            text = theme.text?.toInt(),
            secondaryText = theme.secondaryText?.toInt(),
            accent = theme.accent?.toInt(),
            cornerRadiusDp = theme.cornerRadius?.toFloat() ?: 28f,
            dark = theme.dark,
        )
    }

    override suspend fun sharingOpenSettings() = sdk {
        val c = client()
        val a = activity ?: throw PluginErrors.invalidArgument("activity: the app has no activity in front")
        if (!SettingsCard.show(a, c)) throw PluginErrors.invalidArgument("activity: the app has no activity in front")
    }

    override suspend fun reportChecks(rule: String, checked: Long, flagged: Long) = sdk {
        client().analytics.reportChecks(rule, checked.toInt(), flagged.toInt())
    }
}

/** Lets a call through at most once per [ms], and always when [force] is set. */
internal class Throttle(private val ms: Long, private val clock: () -> Long = System::currentTimeMillis) {
    private var last = Long.MIN_VALUE / 2

    @Synchronized
    fun pass(force: Boolean): Boolean {
        val now = clock()
        if (!force && now - last < ms) return false
        last = now
        return true
    }
}
