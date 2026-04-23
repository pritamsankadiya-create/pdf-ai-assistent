import 'package:googleai_dart/googleai_dart.dart';

import '../models/attached_file.dart';
import 'cache_service.dart';
import 'file_upload_service.dart';
import 'model_router.dart';

class AIService {
  static AIService? _instance;
  late final GoogleAIClient _client;
  late final CacheService _cache;
  late final ModelRouter _router;
  late final FileUploadService _fileUploader;

  static const _primaryModel = 'gemini-2.5-flash';
  static const _fallbackModel = 'gemini-2.0-flash';
  static const _proModel = 'gemini-2.5-pro-preview';
  static const _cooldownDuration = Duration(minutes: 1);

  String _activeModel = _primaryModel;
  DateTime? _fallbackUntil;

  static const _systemInstruction =
      'You are a helpful AI assistant that analyzes documents, images, and data files. '
      'Answer questions about the provided files accurately and concisely. '
      'If the answer is not found in the files, say so clearly. '
      'For PDFs and documents, mention the page number or section heading where you found '
      'the information, formatted as (Page X, Section Y). '
      'For images, describe what you see and extract any visible text. '
      'For spreadsheets and CSV files, analyze the data structure, summarize key metrics, '
      'and reference specific rows/columns when answering.';

  AIService._({required String apiKey}) {
    _client = GoogleAIClient.withApiKey(apiKey);
    _cache = CacheService();
    _router = ModelRouter(_client);
    _fileUploader = FileUploadService(_client);
  }

  static Future<AIService> initialize(String apiKey) async {
    final service = AIService._(apiKey: apiKey);
    await service._cache.initialize();
    _instance = service;
    return service;
  }

  static AIService get instance {
    if (_instance == null) {
      throw StateError('AIService not initialized. Call initialize() first.');
    }
    return _instance!;
  }

  String get currentModel => _activeModel;

  /// Callback signature for cache/routing metadata.
  /// Called with (modelUsed, fromCache, originalQuery).
  Stream<GenerateContentResponse> streamChatResponse({
    required String userQuery,
    required List<AttachedFile> files,
    required List<Content> conversationHistory,
    void Function(String model)? onModelSwitch,
    void Function(String modelUsed, bool fromCache)? onMetadata,
  }) async* {
    final fingerprint = CacheService.generateFileFingerprint(files);

    // 1. Cache check
    final cached = _cache.lookup(userQuery, fingerprint);
    if (cached != null) {
      onMetadata?.call(cached.modelUsed, true);
      yield _syntheticResponse(cached.response);
      return;
    }

    // 2. Route query to determine model
    final route = await _router.routeRequest(userQuery);
    var targetModel = route.modelId;
    onMetadata?.call(targetModel, false);

    // 3. Upload binary files (reuses URIs if still valid)
    await _fileUploader.ensureAllUploaded(files);

    // 4. Build optimized request with file URIs
    final request = _buildOptimizedRequest(
      userQuery,
      files,
      conversationHistory,
    );

    // Auto-recover to primary model after cooldown
    if (_activeModel != _primaryModel &&
        _fallbackUntil != null &&
        DateTime.now().isAfter(_fallbackUntil!)) {
      _activeModel = _primaryModel;
      _fallbackUntil = null;
    }

    // Use routed model (override activeModel for this request)
    final modelToUse = targetModel;

    // 5. Stream with retry logic
    final buffer = StringBuffer();
    await for (final chunk in _streamWithRetry(
      model: modelToUse,
      request: request,
      onModelSwitch: (model) {
        targetModel = model;
        onModelSwitch?.call(model);
      },
    )) {
      final text = chunk.text;
      if (text != null) buffer.write(text);
      yield chunk;
    }

    // 6. Cache the complete response
    if (buffer.isNotEmpty) {
      await _cache.store(CacheEntry(
        normalizedQuery: userQuery,
        response: buffer.toString(),
        modelUsed: targetModel,
        fileFingerprint: fingerprint,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// Re-runs a query with Pro model after user marks response unhelpful.
  Stream<GenerateContentResponse> rerunWithPro({
    required String originalQuery,
    required List<AttachedFile> files,
    required List<Content> conversationHistory,
  }) async* {
    final fingerprint = CacheService.generateFileFingerprint(files);

    // Mark old cache entry as unhelpful
    await _cache.markUnhelpful(originalQuery, fingerprint);

    // Upload files (reuses URIs)
    await _fileUploader.ensureAllUploaded(files);

    final request = _buildOptimizedRequest(
      originalQuery,
      files,
      conversationHistory,
    );

    final buffer = StringBuffer();
    await for (final chunk in _streamWithRetry(
      model: _proModel,
      request: request,
      onModelSwitch: null,
    )) {
      final text = chunk.text;
      if (text != null) buffer.write(text);
      yield chunk;
    }

    // Update cache with Pro response
    if (buffer.isNotEmpty) {
      await _cache.updateResponse(
        originalQuery,
        fingerprint,
        buffer.toString(),
        _proModel,
      );
    }
  }

  void clearFileUploads() {
    _fileUploader.clearAll();
  }

  GenerateContentResponse _syntheticResponse(String text) {
    return GenerateContentResponse(
      candidates: [
        Candidate(
          content: Content.model([Part.text(text)]),
          index: 0,
        ),
      ],
    );
  }

  static const _defaultRetryDelay = Duration(seconds: 15);

  Duration _getRetryDelay(ApiException e) {
    if (e is RateLimitException && e.retryAfter != null) {
      final wait = e.retryAfter!.difference(DateTime.now());
      if (wait.isNegative) return Duration.zero;
      return wait + const Duration(seconds: 1);
    }
    return _defaultRetryDelay;
  }

  Stream<GenerateContentResponse> _tryStream({
    required String model,
    required GenerateContentRequest request,
  }) async* {
    await for (final chunk in _client.models.streamGenerateContent(
      model: model,
      request: request,
    )) {
      yield chunk;
    }
  }

  Stream<GenerateContentResponse> _streamWithRetry({
    required String model,
    required GenerateContentRequest request,
    void Function(String model)? onModelSwitch,
  }) async* {
    final otherModel =
        model == _primaryModel ? _fallbackModel : _primaryModel;

    // Attempt 1: Try the requested model
    try {
      await for (final chunk in _tryStream(model: model, request: request)) {
        yield chunk;
      }
      return;
    } on ApiException catch (e) {
      if (e.statusCode != 429 && e.statusCode != 503) rethrow;

      // Attempt 2: Switch to the other model
      _activeModel = otherModel;
      _fallbackUntil = DateTime.now().add(_cooldownDuration);
      onModelSwitch?.call(otherModel);
      try {
        await for (final chunk
            in _tryStream(model: otherModel, request: request)) {
          yield chunk;
        }
        return;
      } on ApiException catch (e2) {
        if (e2.statusCode != 429 && e2.statusCode != 503) rethrow;

        // Attempt 3: Both models rate-limited — wait, retry original
        final delay = _getRetryDelay(e2);
        onModelSwitch?.call('$model (retrying in ${delay.inSeconds}s)');
        await Future.delayed(delay);
        try {
          await for (final chunk
              in _tryStream(model: model, request: request)) {
            yield chunk;
          }
          _activeModel = model;
          _fallbackUntil = null;
          return;
        } on ApiException catch (e3) {
          if (e3.statusCode != 429 && e3.statusCode != 503) rethrow;

          // Attempt 4: Last try — wait, try the other model
          final delay2 = _getRetryDelay(e3);
          onModelSwitch?.call('$otherModel (retrying in ${delay2.inSeconds}s)');
          await Future.delayed(delay2);
          await for (final chunk
              in _tryStream(model: otherModel, request: request)) {
            yield chunk;
          }
          _activeModel = otherModel;
          return;
        }
      }
    }
  }

  /// Builds a request using file URIs for binary files, inline text for text files.
  GenerateContentRequest _buildOptimizedRequest(
    String userQuery,
    List<AttachedFile> files,
    List<Content> conversationHistory,
  ) {
    final parts = <Part>[];

    for (final file in files) {
      if (file.needsTextConversion) {
        // Text files: send inline (no benefit from Files API)
        parts.add(Part.text('[File: ${file.name}]\n${file.toTextContent()}'));
      } else {
        // Binary files: use file URI if uploaded, fall back to bytes
        final ref = _fileUploader.getCachedRef(file);
        if (ref != null) {
          parts.add(Part.file(ref.uri, mimeType: ref.mimeType));
        } else {
          parts.add(Part.bytes(file.bytes, file.mimeType));
        }
      }
    }

    parts.add(Part.text(userQuery));

    return GenerateContentRequest(
      contents: [...conversationHistory, Content.user(parts)],
      systemInstruction: Content(parts: [Part.text(_systemInstruction)]),
    );
  }
}
