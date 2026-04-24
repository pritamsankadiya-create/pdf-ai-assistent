import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

// ── Transcript segment with timestamp ──────────────────────────────────

class TranscriptSegment {
  final Duration timestamp;
  String text;

  TranscriptSegment({required this.timestamp, required this.text});

  String get formattedTimestamp {
    final minutes = timestamp.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = timestamp.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '[$minutes:$seconds]';
  }
}

enum _PageState {
  initial,
  permissionDenied,
  ready,
  recording,
  paused,
  stopped,
  uploading,
  success,
  error,
}

class AudioTranscriptPage extends StatefulWidget {
  const AudioTranscriptPage({super.key});

  @override
  State<AudioTranscriptPage> createState() => _AudioTranscriptPageState();
}

class _AudioTranscriptPageState extends State<AudioTranscriptPage> with TickerProviderStateMixin {
  final SpeechToText _speech = SpeechToText();

  _PageState _state = _PageState.initial;
  String _liveText = '';
  final List<TranscriptSegment> _segments = [];
  final List<double> _waveform = [];
  String _errorMsg = '';
  Timer? _waveformDecayTimer;

  DateTime? _recordingStartTime;
  Duration _pausedDuration = Duration.zero;
  DateTime? _pauseStartTime;

  bool _isEditing = false;
  late TextEditingController _editController;

  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _requestPermission();
  }

  @override
  void dispose() {
    _stopWaveformDecay();
    WakelockPlus.disable();
    _pulseCtrl.dispose();
    _editController.dispose();
    _speech.stop();
    super.dispose();
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  String get _fullTranscriptText {
    if (_segments.isEmpty) return '';
    return _segments
        .map((s) => '${s.formattedTimestamp} ${s.text}')
        .join('\n');
  }

  Duration get _currentElapsed {
    if (_recordingStartTime == null) return Duration.zero;
    final now = DateTime.now();
    return now.difference(_recordingStartTime!) - _pausedDuration;
  }

  // ── Permission ──────────────────────────────────────────────────────

  Future<void> _requestPermission() async {
    final available = await _speech.initialize(
      onError: (e) => debugPrint('Speech error: ${e.errorMsg}'),
      onStatus: _onSpeechStatus,
    );
    setState(() {
      _state = available ? _PageState.ready : _PageState.permissionDenied;
    });
  }

  // ── Waveform decay — keeps bars alive during speech engine gaps ─────

  void _startWaveformDecay() {
    _waveformDecayTimer?.cancel();
    _waveformDecayTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) {
        if (_state != _PageState.recording || !mounted) {
          _stopWaveformDecay();
          return;
        }
        if (_waveform.isEmpty) return;
        // Smoothly decay the last bar value so waveform fades instead of freezing
        final lastVal = _waveform.last;
        if (lastVal > 0.05) {
          setState(() {
            _waveform.add((lastVal * 0.7).clamp(0.02, 1.0));
            if (_waveform.length > 60) _waveform.removeAt(0);
          });
        }
      },
    );
  }

  void _stopWaveformDecay() {
    _waveformDecayTimer?.cancel();
    _waveformDecayTimer = null;
  }

  // ── Auto-restart listener when speech engine stops on its own ───────

  int _restartAttempts = 0;
  static const int _maxRestartAttempts = 5;

  void _onSpeechStatus(String status) {
    if (status == 'notListening' && _state == _PageState.recording) {
      // Speech engine stopped on its own (final result or silence timeout).
      // Restart listening to keep the session going.
      _restartListening();
    }
  }

  Future<void> _restartListening() async {
    if (_state != _PageState.recording || !mounted) return;

    if (_restartAttempts >= _maxRestartAttempts) {
      // Too many consecutive failures — re-initialize the engine
      _restartAttempts = 0;
      await Future.delayed(const Duration(milliseconds: 500));
      if (_state != _PageState.recording || !mounted) return;

      final ok = await _speech.initialize(
        onError: (e) => debugPrint('Speech error: ${e.errorMsg}'),
        onStatus: _onSpeechStatus,
      );
      if (!ok || _state != _PageState.recording || !mounted) return;
    }

    // Back off slightly: 300ms base + 200ms per attempt
    final delay = Duration(milliseconds: 300 + _restartAttempts * 200);
    await Future.delayed(delay);
    if (_state != _PageState.recording || !mounted) return;

    try {
      await _listenSpeech();
      _restartAttempts = 0; // reset on success
    } catch (e) {
      debugPrint('Restart listen failed: $e');
      _restartAttempts++;
      _restartListening(); // retry with backoff
    }
  }

  // ── Recording ───────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    _liveText = '';
    _segments.clear();
    _waveform.clear();
    _recordingStartTime = DateTime.now();
    _pausedDuration = Duration.zero;
    _pauseStartTime = null;
    _isEditing = false;
    _restartAttempts = 0;
    WakelockPlus.enable();
    _startWaveformDecay();
    setState(() => _state = _PageState.recording);

    await _listenSpeech();
  }

  Future<void> _listenSpeech() async {
    await _speech.listen(
      onResult: _onSpeechResult,
      onSoundLevelChange: (level) {
        setState(() {
          final double normalized;
          if (Platform.isIOS) {
            // iOS reports -50 to 0 dB, but speech sits in ~-35 to -5.
            // Map that narrower range and apply a power curve for
            // visible up/down movement.
            final linear = ((level + 35) / 30).clamp(0.0, 1.0);
            normalized = linear * linear; // emphasize louder peaks
          } else {
            // Android: -2 to 10 dB
            normalized = ((level + 2) / 12).clamp(0.0, 1.0);
          }
          _waveform.add(normalized);
          if (_waveform.length > 60) _waveform.removeAt(0);
        });
      },
      listenOptions: SpeechListenOptions(
        listenMode: ListenMode.dictation,
        partialResults: true,
        cancelOnError: false,
      ),
    );
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    setState(() {
      _liveText = result.recognizedWords;
      if (result.finalResult) {
        if (result.recognizedWords.isNotEmpty) {
          _segments.add(TranscriptSegment(
            timestamp: _currentElapsed,
            text: result.recognizedWords,
          ));
        }
        _liveText = '';
      }
    });
  }

  // ── Pause / Resume ─────────────────────────────────────────────────

  Future<void> _pauseRecording() async {
    await _speech.stop();
    _stopWaveformDecay();
    _pauseStartTime = DateTime.now();
    // Finalize any live text as a segment
    if (_liveText.isNotEmpty) {
      _segments.add(TranscriptSegment(
        timestamp: _currentElapsed,
        text: _liveText,
      ));
      _liveText = '';
    }
    setState(() => _state = _PageState.paused);
  }

  Future<void> _resumeRecording() async {
    if (_pauseStartTime != null) {
      _pausedDuration += DateTime.now().difference(_pauseStartTime!);
      _pauseStartTime = null;
    }
    _startWaveformDecay();
    setState(() => _state = _PageState.recording);
    await _listenSpeech();
  }

  // ── Stop ────────────────────────────────────────────────────────────

  Future<void> _stopRecording() async {
    await _speech.stop();
    _stopWaveformDecay();
    WakelockPlus.disable();
    if (_pauseStartTime != null) {
      _pausedDuration += DateTime.now().difference(_pauseStartTime!);
      _pauseStartTime = null;
    }
    setState(() {
      if (_liveText.isNotEmpty) {
        _segments.add(TranscriptSegment(
          timestamp: _currentElapsed,
          text: _liveText,
        ));
      }
      _liveText = '';
      _state = _PageState.stopped;
      _editController.text = _fullTranscriptText;
    });
  }

  // ── Copy / Share ────────────────────────────────────────────────────

  void _copyTranscript() {
    final text = _isEditing ? _editController.text : _fullTranscriptText;
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transcript copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _shareTranscript() {
    final text = _isEditing ? _editController.text : _fullTranscriptText;
    Share.share(text);
  }

  // ── Edit toggle ─────────────────────────────────────────────────────

  void _toggleEdit() {
    setState(() {
      if (_isEditing) {
        // Save edits back — parse edited text to update segments
        _applyEditedText(_editController.text);
      } else {
        _editController.text = _fullTranscriptText;
      }
      _isEditing = !_isEditing;
    });
  }

  void _applyEditedText(String editedText) {
    // Replace all segments with the edited content as a single segment
    final lines = editedText.split('\n').where((l) => l.trim().isNotEmpty);
    _segments.clear();
    for (final line in lines) {
      // Try to parse "[MM:SS] text" format
      final match = RegExp(r'^\[(\d{2}):(\d{2})\]\s*(.*)$').firstMatch(line);
      if (match != null) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final text = match.group(3)!;
        if (text.isNotEmpty) {
          _segments.add(TranscriptSegment(
            timestamp: Duration(minutes: minutes, seconds: seconds),
            text: text,
          ));
        }
      } else if (line.trim().isNotEmpty) {
        _segments.add(TranscriptSegment(
          timestamp: Duration.zero,
          text: line.trim(),
        ));
      }
    }
  }

  // ── Upload (mocked) ────────────────────────────────────────────────

  Future<void> _uploadTranscript() async {
    if (_isEditing) {
      _applyEditedText(_editController.text);
      _isEditing = false;
    }
    setState(() => _state = _PageState.uploading);

    try {
      // ── Mock delay — replace with real POST later ──
      await Future.delayed(const Duration(seconds: 2));

      setState(() => _state = _PageState.success);
    } catch (e) {
      setState(() {
        _errorMsg = e.toString();
        _state = _PageState.error;
      });
    }
  }

  void _reset() {
    setState(() {
      _segments.clear();
      _liveText = '';
      _waveform.clear();
      _isEditing = false;
      _recordingStartTime = null;
      _pausedDuration = Duration.zero;
      _pauseStartTime = null;
      _restartAttempts = 0;
      _state = _PageState.ready;
    });
  }

  // ── UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        title: const Text('Audio Transcript'),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: switch (_state) {
          _PageState.initial => _buildLoading(),
          _PageState.permissionDenied => _buildPermissionDenied(),
          _PageState.ready => _buildReady(),
          _PageState.recording => _buildRecording(),
          _PageState.paused => _buildPaused(),
          _PageState.stopped => _buildStopped(),
          _PageState.uploading => _buildUploading(),
          _PageState.success => _buildSuccess(),
          _PageState.error => _buildError(),
        },
      ),
    );
  }

  // ── Loading ─────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white70),
          SizedBox(height: 16),
          Text('Requesting microphone access...',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
        ],
      ),
    );
  }

  // ── Permission denied ──────────────────────────────────────────────

  Widget _buildPermissionDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.mic_off, size: 72, color: Colors.redAccent),
            const SizedBox(height: 24),
            const Text(
              'Microphone permission is required to record audio.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => openAppSettings(),
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.deepPurple,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Ready ──────────────────────────────────────────────────────────

  Widget _buildReady() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.mic_none, size: 80, color: Colors.white38),
          const SizedBox(height: 24),
          const Text('Tap the button to start recording',
              style: TextStyle(color: Colors.white54, fontSize: 16)),
          const SizedBox(height: 40),
          _micButton(onTap: _startRecording, recording: false),
        ],
      ),
    );
  }

  // ── Transcript display (shared between recording & paused) ────────

  Widget _buildTranscriptBox() {
    final segmentText = _segments
        .map((s) => '${s.formattedTimestamp} ${s.text}')
        .join('\n');
    final displayText = _liveText.isNotEmpty
        ? '$segmentText\n$_liveText'
        : segmentText;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: Text(
          displayText.isEmpty ? 'Listening...' : displayText,
          style: TextStyle(
            color: displayText.isEmpty ? Colors.white38 : Colors.white,
            fontSize: 18,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  // ── Recording ──────────────────────────────────────────────────────

  Widget _buildRecording() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Waveform
          SizedBox(
            height: 100,
            child: CustomPaint(
              size: const Size(double.infinity, 100),
              painter: _WaveformPainter(_waveform),
            ),
          ),
          const SizedBox(height: 24),
          // Live transcript
          Expanded(child: _buildTranscriptBox()),
          const SizedBox(height: 24),
          // Pause + Stop buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _controlButton(
                onTap: _pauseRecording,
                icon: Icons.pause,
                color: Colors.orange,
                label: 'Pause',
              ),
              const SizedBox(width: 32),
              _controlButton(
                onTap: _stopRecording,
                icon: Icons.stop,
                color: Colors.redAccent,
                label: 'Stop',
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Paused ─────────────────────────────────────────────────────────

  Widget _buildPaused() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Frozen waveform
          SizedBox(
            height: 100,
            child: CustomPaint(
              size: const Size(double.infinity, 100),
              painter: _WaveformPainter(_waveform),
            ),
          ),
          const SizedBox(height: 8),
          const Text('Paused',
              style: TextStyle(
                  color: Colors.orangeAccent,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          // Transcript
          Expanded(child: _buildTranscriptBox()),
          const SizedBox(height: 24),
          // Resume + Stop buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _controlButton(
                onTap: _resumeRecording,
                icon: Icons.play_arrow,
                color: Colors.greenAccent,
                label: 'Resume',
              ),
              const SizedBox(width: 32),
              _controlButton(
                onTap: _stopRecording,
                icon: Icons.stop,
                color: Colors.redAccent,
                label: 'Stop',
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Stopped ────────────────────────────────────────────────────────

  Widget _buildStopped() {
    final hasText = _segments.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.check_circle,
                  color: Colors.greenAccent, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Recording complete',
                    style:
                        TextStyle(color: Colors.greenAccent, fontSize: 16)),
              ),
              // Copy button
              if (hasText)
                IconButton(
                  onPressed: _copyTranscript,
                  icon: const Icon(Icons.copy, color: Colors.white70, size: 20),
                  tooltip: 'Copy transcript',
                ),
              // Share button
              if (hasText)
                IconButton(
                  onPressed: _shareTranscript,
                  icon:
                      const Icon(Icons.share, color: Colors.white70, size: 20),
                  tooltip: 'Share transcript',
                ),
              // Edit toggle
              if (hasText)
                IconButton(
                  onPressed: _toggleEdit,
                  icon: Icon(
                    _isEditing ? Icons.check : Icons.edit,
                    color: _isEditing ? Colors.greenAccent : Colors.white70,
                    size: 20,
                  ),
                  tooltip: _isEditing ? 'Done editing' : 'Edit transcript',
                ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isEditing ? Colors.deepPurple : Colors.white12,
                ),
              ),
              child: _isEditing
                  ? TextField(
                      controller: _editController,
                      maxLines: null,
                      expands: true,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 18, height: 1.5),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Edit your transcript...',
                        hintStyle: TextStyle(color: Colors.white38),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        _fullTranscriptText.isEmpty
                            ? 'No speech detected.'
                            : _fullTranscriptText,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 18, height: 1.5),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Record Again'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: hasText ? _uploadTranscript : null,
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Upload'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  // ── Uploading ──────────────────────────────────────────────────────

  Widget _buildUploading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.deepPurple),
          SizedBox(height: 24),
          Text('Uploading transcript...',
              style: TextStyle(color: Colors.white70, fontSize: 16)),
        ],
      ),
    );
  }

  // ── Success ────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.cloud_done, size: 80, color: Colors.greenAccent),
          const SizedBox(height: 24),
          const Text('Transcript uploaded successfully!',
              style: TextStyle(color: Colors.white, fontSize: 18)),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: _reset,
            icon: const Icon(Icons.mic),
            label: const Text('New Recording'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
              foregroundColor: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }

  // ── Error ──────────────────────────────────────────────────────────

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 72, color: Colors.redAccent),
            const SizedBox(height: 24),
            Text('Upload failed\n$_errorMsg',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 16)),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: _reset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  child: const Text('Discard'),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _uploadTranscript,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ── Control button (Pause/Resume/Stop) ──────────────────────────────

  Widget _controlButton({
    required VoidCallback onTap,
    required IconData icon,
    required Color color,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.4),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  // ── Mic button (ready state) ────────────────────────────────────────

  Widget _micButton({required VoidCallback onTap, required bool recording}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (context, child) {
          final scale = recording ? 1.0 + _pulseCtrl.value * 0.15 : 1.0;
          return Transform.scale(
            scale: scale,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: recording ? Colors.redAccent : Colors.deepPurple,
                boxShadow: [
                  if (recording)
                    BoxShadow(
                      color: Colors.redAccent.withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                ],
              ),
              child: Icon(
                recording ? Icons.stop : Icons.mic,
                color: Colors.white,
                size: 36,
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Waveform painter ──────────────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  final List<double> data;
  _WaveformPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..color = Colors.deepPurpleAccent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final barWidth = size.width / 60;
    final centerY = size.height / 2;

    for (int i = 0; i < data.length; i++) {
      final normalized = data[i].clamp(0.05, 1.0);
      final barHeight = normalized * size.height * 0.8;
      final x = i * barWidth + barWidth / 2;

      canvas.drawLine(
        Offset(x, centerY - barHeight / 2),
        Offset(x, centerY + barHeight / 2),
        paint
          ..color = Colors.deepPurpleAccent
              .withValues(alpha: 0.5 + normalized * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) => true;
}
