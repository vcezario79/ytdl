import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

void main() {
  runApp(const YtDlpApp());
}

// ─── Theme ────────────────────────────────────────────────────────────────────

class YtDlpApp extends StatelessWidget {
  const YtDlpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'yt-dlp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFFF4444),
          brightness: Brightness.dark,
          surface: const Color(0xFF1A1A1A),
          surfaceContainerHighest: const Color(0xFF242424),
        ),
        useMaterial3: true,
        fontFamily: 'monospace',
        cardTheme: CardThemeData(
          color: const Color(0xFF242424),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF333333)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF333333)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF333333)),
          ),
        ),
      ),
      home: const DownloaderPage(),
    );
  }
}

// ─── Model ────────────────────────────────────────────────────────────────────

enum JobStatus { pending, downloading, done, error, cancelled }

class DownloadJob extends ChangeNotifier {
  final String url;
  JobStatus status = JobStatus.pending;
  double progress = 0.0;
  String displayName = '';
  String? errorMessage;
  final List<String> logs = [];
  int? playlistCurrent;
  int? playlistTotal;

  DownloadJob(this.url) {
    displayName = Uri.tryParse(url)?.host.isNotEmpty == true
        ? url.length > 60
            ? '${url.substring(0, 60)}…'
            : url
        : url;
  }

  void addLog(String line) {
    logs.add(line);
    notifyListeners();
  }

  void setProgress(double v) {
    progress = v;
    notifyListeners();
  }

  void setStatus(JobStatus s) {
    status = s;
    notifyListeners();
  }

  void setName(String name) {
    displayName = name;
    notifyListeners();
  }

  void setError(String e) {
    errorMessage = e;
    notifyListeners();
  }

  Process? _process;

  void cancel() {
    if (status == JobStatus.downloading) {
      _process?.kill(ProcessSignal.sigterm);
      status = JobStatus.cancelled;
      notifyListeners();
    } else if (status == JobStatus.pending) {
      status = JobStatus.cancelled;
      notifyListeners();
    }
  }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

class DownloaderPage extends StatefulWidget {
  const DownloaderPage({super.key});

  @override
  State<DownloaderPage> createState() => _DownloaderPageState();
}

class _DownloaderPageState extends State<DownloaderPage> {
  final _urlController = TextEditingController();
  String _downloadPath = '';
  final List<DownloadJob> _jobs = [];
  bool _isDownloading = false;
  File? _logFile;
  String _prefsPath = '';
  bool _playlistSubfolder = true;
  String _librarySize = '';

  @override
  void initState() {
    super.initState();
    final home = Platform.environment['HOME'] ??
        p.join('/home', Platform.environment['USER'] ?? '');
    _downloadPath = home;
    _prefsPath = '$home/.config/ytdlp_ui/prefs.json';

    _logFile = File('ytdlp.log');
    _logFile!.writeAsStringSync(
      '=== Session started: ${DateTime.now()} ===\n',
      mode: FileMode.append,
    );

    _loadPrefs();
    _computeLibrarySize();
  }

  Future<void> _computeLibrarySize() async {
    final dir = Directory('/home/deck/Music');
    if (!dir.existsSync()) return;
    int total = 0;
    await for (final f in dir.list(recursive: true, followLinks: false)) {
      if (f is File) total += await f.length();
    }
    if (mounted) {
      setState(() {
        if (total < 1024 * 1024) {
          _librarySize = '${(total / 1024).toStringAsFixed(1)} KB';
        } else if (total < 1024 * 1024 * 1024) {
          _librarySize = '${(total / (1024 * 1024)).toStringAsFixed(1)} MB';
        } else {
          _librarySize =
              '${(total / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
        }
      });
    }
  }

  void _loadPrefs() {
    try {
      final f = File(_prefsPath);
      if (f.existsSync()) {
        final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (data['lastFolder'] != null) {
          setState(() => _downloadPath = data['lastFolder'] as String);
        }
        if (data['playlistSubfolder'] != null) {
          setState(
              () => _playlistSubfolder = data['playlistSubfolder'] as bool);
        }
      }
    } catch (_) {}
  }

  void _savePrefs() {
    try {
      final f = File(_prefsPath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode({
        'lastFolder': _downloadPath,
        'playlistSubfolder': _playlistSubfolder,
      }));
    } catch (_) {}
  }

  void _writeLog(String tag, String line) {
    try {
      _logFile?.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] [$tag] $line\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  Future<void> _pickFolder() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose Download Location',
      initialDirectory: _downloadPath,
    );
    if (result != null && mounted) {
      setState(() => _downloadPath = result);
      _savePrefs();
    }
  }

  Future<void> _startDownload() async {
    final rawUrls = _urlController.text
        .split('\n')
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList();

    if (rawUrls.isEmpty) {
      _showSnack('Paste at least one URL.', isError: false);
      return;
    }

    final newJobs = rawUrls.map(DownloadJob.new).toList();
    setState(() {
      _jobs.insertAll(0, newJobs);
      _isDownloading = true;
      _urlController.clear();
    });

    for (final job in newJobs) {
      await _runJob(job);
    }

    if (mounted) setState(() => _isDownloading = false);
  }

  Future<void> _runJob(DownloadJob job) async {
    if (job.status == JobStatus.cancelled) return;
    job.setStatus(JobStatus.downloading);

    final outputTemplate = _playlistSubfolder
        ? p.join(_downloadPath, '%(playlist_title)s', '%(title)s.%(ext)s')
        : p.join(_downloadPath, '%(title)s.%(ext)s');
    _writeLog(job.url, 'Starting — output: $outputTemplate');
    _writeLog(job.url, 'Command: yt-dlp ... ${job.url}');

    try {
      final process = await Process.start('yt-dlp', [
        '--extract-audio',
        '--audio-format', 'mp3',
        '--audio-quality', '0', // best VBR
        '--embed-thumbnail',
        '--add-metadata',
        '--newline',
        '--no-color',
        '-o', outputTemplate,
        job.url,
      ]);

      job._process = process;

      // stdout — progress + info lines
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        job.addLog(line);
        _writeLog(job.url, line);

        // progress: [download]  45.2% of ...
        final pct = RegExp(r'\[download\]\s+([\d.]+)%').firstMatch(line);
        if (pct != null) {
          job.setProgress(double.parse(pct.group(1)!) / 100.0);
        }

        // destination title: [ExtractAudio] Destination: /path/Title.mp3
        final dest = RegExp(r'Destination: (.+)$').firstMatch(line);
        if (dest != null) {
          job.setName(p.basenameWithoutExtension(dest.group(1)!));
        }

        // playlist: [download] Downloading item 3 of 45
        final pl = RegExp(r'Downloading item (\d+) of (\d+)').firstMatch(line);
        if (pl != null) {
          job.playlistCurrent = int.parse(pl.group(1)!);
          job.playlistTotal = int.parse(pl.group(2)!);
          job.notifyListeners();
        }
        if (line.contains('[download]') &&
            line.contains('has already been downloaded')) {
          job.setProgress(1.0);
        }
      });

      // stderr — warnings / errors
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.trim().isNotEmpty) {
          job.addLog('⚠ $line');
          _writeLog(job.url, 'STDERR: $line');
        }
      });

      final code = await process.exitCode;
      _writeLog(job.url, 'Process exited with code $code');
      if (job.status == JobStatus.cancelled) {
        // already marked, do nothing
      } else if (code == 0) {
        job.setProgress(1.0);
        job.setStatus(JobStatus.done);
        _computeLibrarySize();
      } else {
        job.setError('yt-dlp exited with code $code');
        job.setStatus(JobStatus.error);
      }
    } on ProcessException catch (e) {
      _writeLog(job.url, 'ProcessException: ${e.message}');
      job.setError(
          'Could not run yt-dlp: ${e.message}\nIs it installed and on your PATH?');
      job.setStatus(JobStatus.error);
    } catch (e) {
      _writeLog(job.url, 'Exception: $e');
      job.setError(e.toString());
      job.setStatus(JobStatus.error);
    }
  }

  void _clearFinished() {
    setState(() => _jobs.removeWhere((j) =>
        j.status == JobStatus.done ||
        j.status == JobStatus.error ||
        j.status == JobStatus.cancelled));
  }

  void _showSnack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? const Color(0xFFB00020) : null,
    ));
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        elevation: 0,
        titleSpacing: 20,
        title: Row(children: [
          Icon(Icons.music_note_rounded, color: cs.primary, size: 22),
          const SizedBox(width: 8),
          Text('yt-dlp',
              style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1)),
          const SizedBox(width: 4),
          Text('downloader',
              style: TextStyle(
                  color: cs.onSurface.withOpacity(0.5), fontSize: 13)),
        ]),
        actions: [
          if (_jobs.any((j) =>
              j.status == JobStatus.done ||
              j.status == JobStatus.error ||
              j.status == JobStatus.cancelled))
            TextButton.icon(
              onPressed: _clearFinished,
              icon: const Icon(Icons.cleaning_services_rounded, size: 16),
              label: const Text('Clear finished'),
              style: TextButton.styleFrom(
                  foregroundColor: cs.onSurface.withOpacity(0.5)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Input card ──────────────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Location row
                    Row(children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: 'Save to',
                            prefixIcon: Icon(Icons.folder_rounded,
                                color: cs.primary, size: 18),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                          child: Text(
                            _downloadPath,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _pickFolder,
                        icon: const Icon(Icons.folder_open_rounded, size: 16),
                        label: const Text('Browse'),
                        style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 13)),
                      ),
                    ]),
                    const SizedBox(height: 12),

                    // URL input
                    TextField(
                      controller: _urlController,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 13, height: 1.5),
                      decoration: const InputDecoration(
                        hintText:
                            'Paste one or more URLs here (one per line)\nhttps://youtube.com/watch?v=…',
                        alignLabelWithHint: true,
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Format badge + download button
                    Row(children: [
                      _Badge(icon: Icons.music_note_rounded, label: 'MP3'),
                      const SizedBox(width: 8),
                      _Badge(icon: Icons.star_rounded, label: 'Best quality'),
                      const SizedBox(width: 8),
                      _Badge(
                          icon: Icons.image_rounded, label: 'Embed thumbnail'),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          setState(
                              () => _playlistSubfolder = !_playlistSubfolder);
                          _savePrefs();
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _playlistSubfolder
                                ? cs.primary.withOpacity(0.15)
                                : const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _playlistSubfolder
                                  ? cs.primary.withOpacity(0.5)
                                  : const Color(0xFF3A3A3A),
                            ),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.folder_special_rounded,
                                size: 12,
                                color: _playlistSubfolder
                                    ? cs.primary
                                    : const Color(0xFF888888)),
                            const SizedBox(width: 4),
                            Text('Playlist subfolders',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: _playlistSubfolder
                                        ? cs.primary
                                        : const Color(0xFF888888))),
                          ]),
                        ),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _isDownloading ? null : _startDownload,
                        icon: _isDownloading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.download_rounded, size: 18),
                        label: Text(
                            _isDownloading ? 'Downloading…' : 'Download',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 13)),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Jobs list ───────────────────────────────────────────────────
            Expanded(
              child: _jobs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.download_rounded,
                              size: 48, color: cs.onSurface.withOpacity(0.15)),
                          const SizedBox(height: 12),
                          Text('No downloads yet',
                              style: TextStyle(
                                  color: cs.onSurface.withOpacity(0.3),
                                  fontSize: 14)),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: _jobs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (ctx, i) =>
                          _JobTile(key: ObjectKey(_jobs[i]), job: _jobs[i]),
                    ),
            ),
            if (_librarySize.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                Icon(Icons.library_music_rounded,
                    size: 13, color: cs.onSurface.withOpacity(0.3)),
                const SizedBox(width: 5),
                Text(
                  'Library: $_librarySize',
                  style: TextStyle(
                      fontSize: 11, color: cs.onSurface.withOpacity(0.3)),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Job tile ─────────────────────────────────────────────────────────────────

class _JobTile extends StatefulWidget {
  final DownloadJob job;
  const _JobTile({super.key, required this.job});

  @override
  State<_JobTile> createState() => _JobTileState();
}

class _JobTileState extends State<_JobTile> {
  bool _logsExpanded = false;
  final _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.job.addListener(_onJobChanged);
  }

  @override
  void dispose() {
    widget.job.removeListener(_onJobChanged);
    _logScroll.dispose();
    super.dispose();
  }

  void _onJobChanged() {
    if (mounted) {
      setState(() {});
      if (_logsExpanded) _scrollLogs();
    }
  }

  void _scrollLogs() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.animateTo(
          _logScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  (Color, IconData, String) _statusInfo(JobStatus s) => switch (s) {
        JobStatus.pending => (
            Colors.grey,
            Icons.hourglass_empty_rounded,
            'Pending'
          ),
        JobStatus.downloading => (
            const Color(0xFF4FC3F7),
            Icons.downloading_rounded,
            'Downloading'
          ),
        JobStatus.done => (
            const Color(0xFF66BB6A),
            Icons.check_circle_rounded,
            'Done'
          ),
        JobStatus.error => (
            const Color(0xFFEF5350),
            Icons.error_rounded,
            'Error'
          ),
        JobStatus.cancelled => (
            const Color(0xFFFFB74D),
            Icons.cancel_rounded,
            'Cancelled'
          ),
      };

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    final (color, icon, label) = _statusInfo(job.status);
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  job.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
              if (job.status == JobStatus.downloading ||
                  job.status == JobStatus.pending)
                InkWell(
                  onTap: widget.job.cancel,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.stop_circle_rounded,
                          size: 14,
                          color: const Color(0xFFFFB74D).withOpacity(0.8)),
                      const SizedBox(width: 4),
                      Text('Cancel',
                          style: TextStyle(
                              fontSize: 11,
                              color: const Color(0xFFFFB74D).withOpacity(0.8))),
                    ]),
                  ),
                ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
            ]),
            const SizedBox(height: 10),

            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: job.status == JobStatus.pending
                    ? 0
                    : job.status == JobStatus.downloading && job.progress == 0
                        ? null // indeterminate while fetching metadata
                        : job.progress,
                minHeight: 5,
                backgroundColor: const Color(0xFF333333),
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),

            // Playlist counter
            if (job.playlistTotal != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.queue_music_rounded,
                    size: 13, color: color.withOpacity(0.7)),
                const SizedBox(width: 5),
                Text(
                  'Track ${job.playlistCurrent} of ${job.playlistTotal}',
                  style: TextStyle(fontSize: 11, color: color.withOpacity(0.7)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: job.playlistCurrent! / job.playlistTotal!,
                      minHeight: 3,
                      backgroundColor: const Color(0xFF333333),
                      valueColor:
                          AlwaysStoppedAnimation(color.withOpacity(0.5)),
                    ),
                  ),
                ),
              ]),
            ],

            // Error message
            if (job.errorMessage != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF3E1A1A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF7B2020)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Color(0xFFEF5350), size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        job.errorMessage!,
                        style: const TextStyle(
                            color: Color(0xFFEF9A9A),
                            fontSize: 11,
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 4),

            // Log toggle
            Row(children: [
              InkWell(
                onTap: () {
                  setState(() => _logsExpanded = !_logsExpanded);
                  if (!_logsExpanded) _scrollLogs();
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(
                      _logsExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: cs.onSurface.withOpacity(0.4),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '${job.logs.length} log lines',
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurface.withOpacity(0.4)),
                    ),
                  ]),
                ),
              ),
              const Spacer(),
              if (job.logs.isNotEmpty)
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: job.logs.join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Logs copied to clipboard'),
                          duration: Duration(seconds: 2)),
                    );
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(children: [
                      Icon(Icons.copy_rounded,
                          size: 13, color: cs.onSurface.withOpacity(0.3)),
                      const SizedBox(width: 4),
                      Text('Copy logs',
                          style: TextStyle(
                              fontSize: 11,
                              color: cs.onSurface.withOpacity(0.3))),
                    ]),
                  ),
                ),
            ]),

            // Log panel
            if (_logsExpanded && job.logs.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                height: 180,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E0E0E),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFF2A2A2A)),
                ),
                child: Scrollbar(
                  controller: _logScroll,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _logScroll,
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      job.logs.join('\n'),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        height: 1.6,
                        color: cs.onSurface.withOpacity(0.7),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Badge widget ─────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Badge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: const Color(0xFF888888)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
      ]),
    );
  }
}
