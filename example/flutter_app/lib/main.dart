import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/doom_monitor_client.dart';

void main() {
  runApp(const _DoomFlutterApp());
}

class _DoomFlutterApp extends StatelessWidget {
  const _DoomFlutterApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WASD DOOM Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xfff97316),
          secondary: Color(0xff22d3ee),
          surface: Color(0xff111827),
        ),
        scaffoldBackgroundColor: const Color(0xff030712),
        useMaterial3: true,
      ),
      home: const _DoomHomePage(),
    );
  }
}

class _DoomHomePage extends StatefulWidget {
  const _DoomHomePage();

  @override
  State<_DoomHomePage> createState() => _DoomHomePageState();
}

class _DoomHomePageState extends State<_DoomHomePage> {
  final DoomMonitorClient _client = createDoomMonitorClient();
  bool _running = false;
  DoomSnapshot? _snapshot;
  String _log = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBundledSnapshot();
  }

  Future<void> _loadBundledSnapshot() async {
    setState(() {
      _running = true;
      _error = null;
    });
    try {
      final reportText = await rootBundle.loadString(
        'assets/doom/report_bootstrap.json',
      );
      final report = jsonDecode(reportText);
      if (report is! Map<String, dynamic>) {
        throw StateError('Invalid bundled report format.');
      }
      final bytesData = await rootBundle.load(
        'assets/doom/frame_bootstrap.bmp',
      );
      final frameBytes = bytesData.buffer.asUint8List();
      final snapshot = DoomSnapshot.fromReport(
        report,
        frameBytes: frameBytes,
        framePath: 'assets/doom/frame_bootstrap.bmp',
      );
      setState(() {
        _snapshot = snapshot;
        _log = 'Loaded bundled DOOM frame and report.';
      });
    } catch (error) {
      setState(() {
        _error = error.toString();
      });
    } finally {
      setState(() {
        _running = false;
      });
    }
  }

  Future<void> _runLiveMonitor() async {
    setState(() {
      _running = true;
      _error = null;
    });
    final result = await _client.runMonitor();
    if (!mounted) {
      return;
    }

    setState(() {
      _running = false;
      _log = result.log;
      if (result.ok && result.snapshot != null) {
        _snapshot = result.snapshot;
        _error = null;
      } else {
        _error = result.error ?? 'DOOM monitor failed.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Scaffold(
      appBar: AppBar(
        title: const Text('WASD DOOM Monitor'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                _client.supportsLiveMonitor
                    ? 'Live Monitor Ready'
                    : 'Bundled Mode',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff0b1220), Color(0xff111827), Color(0xff1f2937)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatusChip(
                      label: 'health',
                      value: snapshot?.health ?? 'loading',
                    ),
                    _StatusChip(
                      label: 'source',
                      value: snapshot?.source ?? '-',
                    ),
                    _StatusChip(
                      label: 'frames',
                      value: '${snapshot?.frameCount ?? 0}',
                    ),
                    _StatusChip(
                      label: 'palette',
                      value: '${snapshot?.paletteUpdates ?? 0}',
                    ),
                    _StatusChip(
                      label: 'size',
                      value: snapshot == null
                          ? '-'
                          : '${snapshot.windowWidth}x${snapshot.windowHeight}',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Card(
                          color: const Color(0xff020617),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _FrameView(
                              bytes: snapshot?.frameBytes,
                              caption:
                                  snapshot?.framePath ?? 'No frame available.',
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: Card(
                          color: const Color(0xff111827),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _ReportView(
                              snapshot: snapshot,
                              log: _log,
                              error: _error,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _running ? null : _loadBundledSnapshot,
                        icon: const Icon(Icons.photo_library),
                        label: const Text('Load Bundled Snapshot'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: !_client.supportsLiveMonitor || _running
                            ? null
                            : _runLiveMonitor,
                        icon: _running
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.play_arrow),
                        label: Text(
                          _client.supportsLiveMonitor
                              ? 'Run Live Monitor (Node)'
                              : 'Live Monitor Unavailable',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FrameView extends StatelessWidget {
  const _FrameView({required this.bytes, required this.caption});

  final Uint8List? bytes;
  final String caption;

  @override
  Widget build(BuildContext context) {
    if (bytes == null || bytes!.isEmpty) {
      return const Center(child: Text('No frame image loaded.'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xfff97316), width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                bytes!,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.none,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xff9ca3af), fontSize: 12),
        ),
      ],
    );
  }
}

class _ReportView extends StatelessWidget {
  const _ReportView({
    required this.snapshot,
    required this.log,
    required this.error,
  });

  final DoomSnapshot? snapshot;
  final String log;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      if (snapshot != null) ...[
        'exitCode: ${snapshot!.exitCode}',
        'health: ${snapshot!.health}',
        'frameCount: ${snapshot!.frameCount}',
        'paletteUpdates: ${snapshot!.paletteUpdates}',
        'uniqueFrameHashes: ${snapshot!.uniqueFrameHashes}',
      ],
      if (snapshot?.callbackTrace.isNotEmpty ?? false) ...[
        '',
        'callbackTrace:',
        ...snapshot!.callbackTrace.map((line) => '  $line'),
      ],
      if (log.trim().isNotEmpty) ...['', 'log:', log.trim()],
      if (error != null) ...['', 'error:', error!],
    ];

    return SingleChildScrollView(
      child: SelectableText(
        lines.isEmpty ? 'No report loaded.' : lines.join('\n'),
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xff374151)),
        borderRadius: BorderRadius.circular(999),
        color: const Color(0xff0f172a),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
