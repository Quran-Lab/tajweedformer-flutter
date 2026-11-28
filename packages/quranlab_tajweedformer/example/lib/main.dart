// The smallest screen around the four calls of every Quran Lab SDK, on Android, iOS, Windows, Linux and the web:
// the model loading with its download progress, "Play sample" (a sample clip, no microphone), "Recite" (the SDK's
// microphone; on Windows and Linux the C SDK has none, and the button shows its runtime_unsupported), the tokens as
// they come (tentative ones dimmed), "Stop", "Diagnose" and the sharing settings.
//
// Run it with a key made for this app's identifiers (ai.quranlab.tajweedformer.flutter.example; a desktop key on
// Windows, Linux and the Mac, a web key on the web):
//   flutter run --dart-define=QURANLAB_KEY=qlk_v1_...
// On Windows (an app without a package identity) also the app id the desktop key is registered for:
//   flutter run -d windows --dart-define=QURANLAB_KEY=qlk_v1_... --dart-define=QURANLAB_APP_ID=...
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:quranlab_tajweedformer/quranlab_tajweedformer.dart';

const _key = String.fromEnvironment('QURANLAB_KEY');
const _appId = String.fromEnvironment('QURANLAB_APP_ID');

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'TajweedFormer',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF2A3B8F)),
        darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF2A3B8F), brightness: Brightness.dark),
        home: const ExampleScreen(),
      );
}

class ExampleScreen extends StatefulWidget {
  const ExampleScreen({super.key});

  @override
  State<ExampleScreen> createState() => _ExampleScreenState();
}

class _ExampleScreenState extends State<ExampleScreen> with WidgetsBindingObserver {
  TajweedClient? _client;
  TajweedModel? _model;
  TajweedSession? _session;
  StreamSubscription<TajweedChunk>? _chunks;
  StreamSubscription<TajweedEvent>? _events;
  TajweedDecoded? _heard;
  String _status = 'Starting';
  double? _progress;
  String? _diagnosis;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chunks?.cancel();
    _events?.cancel();
    super.dispose();
  }

  // A `listen` take ends when the app leaves the foreground; the next one starts from the button again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _session != null) setState(() => _status = 'Ended: the app left the foreground');
  }

  Future<void> _load() async {
    if (_key.isEmpty) {
      setState(() => _status = 'No key: run with --dart-define=QURANLAB_KEY=qlk_v1_...');
      return;
    }
    try {
      final client = await TajweedClient.create(_key,
          options: TajweedClientOptions(appId: _appId.isEmpty ? null : _appId));
      setState(() {
        _client = client;
        _status = 'Loading the model';
      });
      final model = await client.model(onProgress: (done, total) {
        if (mounted && total > 0) setState(() => _progress = done / total);
      });
      setState(() {
        _model = model;
        _progress = null;
        _status = 'Model ${model.version} ready (${model.chunkMs()} ms chunks)';
      });
    } on TajweedError catch (e) {
      setState(() => _status = '${e.code}: ${e.message}\n${e.fix}');
    }
  }

  Future<void> _start(Future<TajweedSession> Function(TajweedModel m) open) async {
    final model = _model;
    if (model == null || _session != null) return;
    try {
      final session = await open(model);
      setState(() {
        _session = session;
        _heard = null;
        _status = 'Listening';
      });
      _chunks = session.chunks.listen((chunk) => setState(() => _heard = chunk.decoded));
      _events = session.events.listen((event) {
        if (event is TajweedEnded) _done('Ended: ${event.reason.name}${event.error == null ? '' : ' (${event.error!.code})'}');
      });
    } on TajweedError catch (e) {
      setState(() => _status = '${e.code}: ${e.message}');
    }
  }

  Future<void> _stop() async {
    final session = _session;
    if (session == null) return;
    try {
      final heads = await session.finish();
      _done('Finished: ${heads.decoded().tokens.length} tokens, heads ${heads.names.join(', ')}');
    } on TajweedError catch (e) {
      _done('${e.code}: ${e.message}');
    }
  }

  void _done(String status) {
    _chunks?.cancel();
    _events?.cancel();
    if (mounted) {
      setState(() {
        _session = null;
        _status = status;
      });
    }
  }

  Future<void> _diagnose() async {
    final client = _client;
    if (client == null) return;
    final d = await client.diagnose();
    setState(() => _diagnosis = d.json);
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final listening = _session != null;
    final heard = _heard;
    final dim = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4);
    return Scaffold(
      appBar: AppBar(title: const Text('TajweedFormer'), actions: [
        IconButton(
          tooltip: 'Sharing settings',
          icon: const Icon(Icons.volunteer_activism_outlined),
          onPressed: _client == null ? null : () => _client!.sharing.openSettings(),
        ),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(_status),
        if (_progress != null) Padding(padding: const EdgeInsets.only(top: 8), child: LinearProgressIndicator(value: _progress)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton(
            onPressed: model == null || listening || model.sampleClips.isEmpty
                ? null
                : () => _start((m) => m.listenFrom(m.sampleClips.first)),
            child: const Text('Play sample'),
          ),
          FilledButton(
            onPressed: model == null || listening
                ? null
                : () => _start((m) => m.listen(options: const TajweedSessionOptions(endOnSilenceMs: 1500))),
            child: const Text('Recite'),
          ),
          OutlinedButton(onPressed: listening ? _stop : null, child: const Text('Stop')),
          OutlinedButton(onPressed: _client == null ? null : _diagnose, child: const Text('Diagnose')),
        ]),
        const SizedBox(height: 24),
        if (heard != null)
          Text.rich(
            TextSpan(children: [
              for (var i = 0; i < heard.tokens.length; i++)
                TextSpan(
                  text: '${heard.tokens[i].name} ',
                  // settled tokens will not change any more; the ones after them may
                  style: TextStyle(color: i < heard.settled ? null : dim),
                ),
            ]),
            style: const TextStyle(fontSize: 22),
          ),
        if (_diagnosis != null) ...[
          const SizedBox(height: 24),
          SelectableText(_diagnosis!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ]),
    );
  }
}
