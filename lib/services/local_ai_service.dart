import 'package:flutter/services.dart';

enum LocalAIStatus { ready, downloading, unavailable, error }

class LocalAIService {
  static const _methodChannel =
      MethodChannel('com.example.pdf_ai_assistant/local_ai');
  static const _streamChannel =
      EventChannel('com.example.pdf_ai_assistant/local_ai_stream');

  static LocalAIService? _instance;

  LocalAIStatus _status = LocalAIStatus.unavailable;
  String _statusMessage = 'Not initialized';

  LocalAIStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isReady => _status == LocalAIStatus.ready;

  LocalAIService._();

  static LocalAIService get instance {
    _instance ??= LocalAIService._();
    return _instance!;
  }

  /// Initialize the on-device Gemini Nano model.
  Future<LocalAIStatus> initialize() async {
    try {
      final result =
          await _methodChannel.invokeMapMethod<String, dynamic>('initialize');
      _updateStatus(result);
      return _status;
    } on PlatformException catch (e) {
      _status = LocalAIStatus.unavailable;
      _statusMessage = e.message ?? 'Platform error';
      return _status;
    }
  }

  /// Check if the model is ready.
  Future<LocalAIStatus> checkStatus() async {
    try {
      final result =
          await _methodChannel.invokeMapMethod<String, dynamic>('checkStatus');
      _updateStatus(result);
      return _status;
    } on PlatformException {
      return _status;
    }
  }

  /// Generate a single response (non-streaming).
  Future<String> generateContent(String prompt) async {
    try {
      final result = await _methodChannel
          .invokeMapMethod<String, dynamic>('generateContent', {
        'prompt': prompt,
      });

      if (result?['success'] == true) {
        return result!['text'] as String;
      } else {
        throw Exception(result?['error'] ?? 'Unknown error');
      }
    } on PlatformException catch (e) {
      throw Exception(e.message);
    }
  }

  /// Generate a streaming response. Each event contains a text chunk.
  Stream<String> generateContentStream(String prompt) {
    return _streamChannel
        .receiveBroadcastStream({'prompt': prompt}).map((event) {
      final map = Map<String, dynamic>.from(event as Map);
      return map['text'] as String;
    });
  }

  /// Close and release resources.
  Future<void> close() async {
    await _methodChannel.invokeMethod('close');
    _status = LocalAIStatus.unavailable;
    _statusMessage = 'Closed';
  }

  void _updateStatus(Map<String, dynamic>? result) {
    final statusStr = result?['status'] as String? ?? 'unavailable';
    _statusMessage = result?['message'] as String? ?? '';
    _status = switch (statusStr) {
      'ready' => LocalAIStatus.ready,
      'downloading' => LocalAIStatus.downloading,
      'error' => LocalAIStatus.error,
      _ => LocalAIStatus.unavailable,
    };
  }
}
