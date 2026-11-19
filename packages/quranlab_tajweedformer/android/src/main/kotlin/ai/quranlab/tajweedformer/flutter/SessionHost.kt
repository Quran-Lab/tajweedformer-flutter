package ai.quranlab.tajweedformer.flutter

import ai.quranlab.tajweedformer.TajweedSession
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * One take of the Dart side: the SDK's Session, its two flows collected and sent to Dart as they come, and the
 * pushes run one after another in the order Dart sent them. [emit] is called on [main] only (an event sink must be).
 */
internal class SessionHost(
    val id: Long,
    val session: TajweedSession,
    val topK: Int,
    private val scope: CoroutineScope,
    private val work: CoroutineDispatcher,
    private val main: CoroutineDispatcher,
    private val emit: (UpdateMessage) -> Unit,
    private val onOver: (SessionHost) -> Unit,
) {
    private val encoder = DeltaEncoder(topK)
    private val pushes = Channel<Pair<FloatArray, CompletableDeferred<Unit>>>(Channel.UNLIMITED)

    /** True until both flows have ended: the take is open. */
    @Volatile var open = true
        private set

    private val collector: Job = scope.launch(work) {
        val chunks = launch { session.chunks.collect { c -> val m = Sdk.chunk(c, encoder); withContext(main) { emit(ChunkUpdate(id, m)) } } }
        val events = launch { session.events.collect { e -> val m = Sdk.event(e); withContext(main) { emit(EventUpdate(id, m)) } } }
        try {
            joinAll(chunks, events)
        } finally {
            open = false
            pushes.close()
            withContext(main + kotlinx.coroutines.NonCancellable) {
                emit(ClosedUpdate(id))
                onOver(this@SessionHost)
            }
        }
    }

    private val pusher: Job = scope.launch(work) {
        for ((samples, done) in pushes) {
            try {
                session.push(samples)
                done.complete(Unit)
            } catch (t: Throwable) {
                done.completeExceptionally(t)
            }
        }
    }

    /** Queued in arrival order; returns when the SDK has taken the samples (its own back pressure). */
    suspend fun push(samples: FloatArray) {
        val done = CompletableDeferred<Unit>()
        if (pushes.trySend(samples to done).isFailure) {
            // the take is over: the SDK's own answer for a push after the end
            session.push(samples)
            return
        }
        done.await()
    }

    /** Stops listening to the SDK (the plugin is going away); the take itself is cancelled by the caller. */
    fun detach() {
        collector.cancel()
        pusher.cancel()
        pushes.close()
    }
}
