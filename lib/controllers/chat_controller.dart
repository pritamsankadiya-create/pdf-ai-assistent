import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:googleai_dart/googleai_dart.dart';

import '../models/attached_file.dart';
import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../services/local_ai_service.dart';

enum AISource { cloud, local }

class ChatController extends GetxController {
  final messages = <ChatMessage>[].obs;
  final isLoading = false.obs;
  final loadingStatus = ''.obs;
  final fileNames = <String>[].obs;
  final aiSource = AISource.cloud.obs;
  final localAIStatus = LocalAIStatus.unavailable.obs;

  final List<AttachedFile> _files = [];

  bool get hasFiles => _files.isNotEmpty;

  @override
  void onInit() {
    super.onInit();
    _initLocalAI();
  }

  Future<void> _initLocalAI() async {
    final status = await LocalAIService.instance.initialize();
    localAIStatus.value = status;
  }

  void toggleAISource() {
    if (aiSource.value == AISource.cloud) {
      switch (localAIStatus.value) {
        case LocalAIStatus.ready:
          aiSource.value = AISource.local;
          _addSystemMessage('Switched to on-device Gemini Nano (offline)');
          _warnIncompatibleFiles(_files);
        case LocalAIStatus.downloading:
          _addSystemMessage(
            'Local AI model is still downloading. Please wait until the download completes and try again.',
          );
        case LocalAIStatus.unavailable:
          _addSystemMessage(
            'Local AI is not available on this device. ${LocalAIService.instance.statusMessage}',
          );
        case LocalAIStatus.error:
          _addSystemMessage(
            'Local AI encountered an error: ${LocalAIService.instance.statusMessage}',
          );
      }
    } else {
      aiSource.value = AISource.cloud;
      _addSystemMessage('Switched to cloud Gemini');
    }
  }

  Future<void> pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: AttachedFile.supportedExtensions,
      withData: true,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) return;

    final validFiles = result.files.where((f) => f.bytes != null).toList();
    if (validFiles.isEmpty) return;

    _files.clear();
    fileNames.clear();
    messages.clear();
    AIService.instance.clearFileUploads();

    for (final file in validFiles) {
      final ext = file.extension ?? '';
      _files.add(AttachedFile(
        name: file.name,
        mimeType: AttachedFile.mimeTypeFromExtension(ext),
        bytes: file.bytes!,
      ));
      fileNames.add(file.name);
    }

    final names = fileNames.join(', ');
    final label = fileNames.length == 1
        ? 'File loaded: $names'
        : '${fileNames.length} files loaded: $names';

    _addSystemMessage(label);

    if (aiSource.value == AISource.local) {
      _warnIncompatibleFiles(_files);
    }
  }

  Future<void> sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    // Cloud mode requires files; local mode can work with just text
    if (aiSource.value == AISource.cloud && !hasFiles) return;

    // Clear previous "model busy" messages to avoid clutter
    _clearModelSwitchMessages();

    messages.add(ChatMessage(
      text: text,
      role: MessageRole.user,
      timestamp: DateTime.now(),
    ));

    var aiMessageIndex = messages.length;
    messages.add(ChatMessage(
      text: '',
      role: MessageRole.ai,
      timestamp: DateTime.now(),
    ));

    isLoading.value = true;

    if (aiSource.value == AISource.local) {
      await _sendLocal(text, aiMessageIndex);
    } else {
      await _sendCloud(text, aiMessageIndex);
    }

    isLoading.value = false;
    loadingStatus.value = '';
  }

  Future<void> _sendCloud(String text, int aiMessageIndex) async {
    loadingStatus.value = 'Thinking...';
    try {
      final history = _buildConversationHistory();
      String? modelUsed;
      bool fromCache = false;

      final stream = AIService.instance.streamChatResponse(
        userQuery: text,
        files: _files,
        conversationHistory: history,
        onModelSwitch: (model) {
          loadingStatus.value = 'Switching to $model...';
          messages.insert(
            aiMessageIndex,
            ChatMessage(
              text: 'Primary model busy, switching to $model',
              role: MessageRole.system,
              timestamp: DateTime.now(),
            ),
          );
          aiMessageIndex++;
        },
        onMetadata: (model, cached) {
          modelUsed = model;
          fromCache = cached;
          if (cached) {
            loadingStatus.value = 'From cache...';
          } else {
            loadingStatus.value = 'Using $model...';
          }
        },
      );

      final buffer = StringBuffer();
      await for (final chunk in stream) {
        final chunkText = chunk.text;
        if (chunkText != null) {
          buffer.write(chunkText);
          messages[aiMessageIndex] = messages[aiMessageIndex].copyWith(
            text: buffer.toString(),
            modelUsed: modelUsed,
            fromCache: fromCache,
            originalQuery: text,
          );
          messages.refresh();
        }
      }
    } catch (e) {
      messages[aiMessageIndex] = messages[aiMessageIndex].copyWith(
        text: 'Error: $e',
      );
      messages.refresh();
    }
  }

  /// Re-runs a query with Pro model when user marks a response as not helpful.
  Future<void> markNotHelpful(int messageIndex) async {
    if (messageIndex < 0 || messageIndex >= messages.length) return;

    final msg = messages[messageIndex];
    if (msg.role != MessageRole.ai || msg.text.isEmpty) return;

    // Mark the existing message as unhelpful
    messages[messageIndex] = msg.copyWith(wasHelpful: false);
    messages.refresh();

    // Add a new AI message placeholder
    final newIndex = messages.length;
    messages.add(ChatMessage(
      text: '',
      role: MessageRole.ai,
      timestamp: DateTime.now(),
    ));

    isLoading.value = true;
    loadingStatus.value = 'Re-generating with Pro...';

    try {
      final query = msg.originalQuery ?? '';
      if (query.isEmpty) {
        messages[newIndex] = messages[newIndex].copyWith(
          text: 'Unable to re-run: original query not found.',
        );
        messages.refresh();
        isLoading.value = false;
        loadingStatus.value = '';
        return;
      }

      final history = _buildConversationHistory();
      final stream = AIService.instance.rerunWithPro(
        originalQuery: query,
        files: _files,
        conversationHistory: history,
      );

      final buffer = StringBuffer();
      await for (final chunk in stream) {
        final chunkText = chunk.text;
        if (chunkText != null) {
          buffer.write(chunkText);
          messages[newIndex] = messages[newIndex].copyWith(
            text: buffer.toString(),
            modelUsed: 'gemini-2.5-pro-preview',
            fromCache: false,
            originalQuery: query,
          );
          messages.refresh();
        }
      }
    } catch (e) {
      messages[newIndex] = messages[newIndex].copyWith(
        text: 'Error re-generating: $e',
      );
      messages.refresh();
    }

    isLoading.value = false;
    loadingStatus.value = '';
  }

  Future<void> _sendLocal(String text, int aiMessageIndex) async {
    loadingStatus.value = 'On-device processing...';
    try {
      // Build a prompt that includes file context for local model
      final prompt = _buildLocalPrompt(text);

      final buffer = StringBuffer();
      await for (final chunk
          in LocalAIService.instance.generateContentStream(prompt)) {
        buffer.write(chunk);
        messages[aiMessageIndex] = messages[aiMessageIndex].copyWith(
          text: buffer.toString(),
        );
        messages.refresh();
      }

      // If streaming returned nothing, try non-streaming
      if (buffer.isEmpty) {
        final response =
            await LocalAIService.instance.generateContent(prompt);
        messages[aiMessageIndex] = messages[aiMessageIndex].copyWith(
          text: response,
        );
        messages.refresh();
      }
    } catch (e) {
      messages[aiMessageIndex] = messages[aiMessageIndex].copyWith(
        text: 'Local AI error: $e',
      );
      messages.refresh();
    }
  }

  String _buildLocalPrompt(String userQuery) {
    final buffer = StringBuffer();

    // Add text content from files (local model can't process binary)
    for (final file in _files) {
      if (file.needsTextConversion) {
        buffer.writeln('[File: ${file.name}]');
        buffer.writeln(file.toTextContent());
        buffer.writeln();
      }
    }

    // Add recent conversation context (limited for local model token limits)
    final recent = messages
        .where((m) => m.role != MessageRole.system && m.text.isNotEmpty)
        .toList();
    final contextMessages = recent.length > 6 ? recent.sublist(recent.length - 6) : recent;
    for (final msg in contextMessages) {
      final role = msg.role == MessageRole.user ? 'User' : 'AI';
      buffer.writeln('$role: ${msg.text}');
    }

    buffer.writeln('User: $userQuery');
    buffer.writeln('AI:');

    return buffer.toString();
  }

  List<Content> _buildConversationHistory() {
    final history = <Content>[];
    for (final msg in messages) {
      switch (msg.role) {
        case MessageRole.user:
          history.add(Content.user([Part.text(msg.text)]));
        case MessageRole.ai:
          if (msg.text.isNotEmpty) {
            history.add(Content.model([Part.text(msg.text)]));
          }
        case MessageRole.system:
          break;
      }
    }
    return history;
  }

  void _warnIncompatibleFiles(List<AttachedFile> files) {
    final incompatible = files.where((f) => !f.isLocalAICompatible).toList();
    if (incompatible.isEmpty) return;

    final names = incompatible.map((f) => f.name).join(', ');
    _addSystemMessage(
      'Note: $names cannot be processed by on-device AI — only text-based files are supported locally',
    );
  }

  static const _modelSwitchPrefix = 'Primary model busy, switching to';

  /// Removes all "model busy" system messages from chat history.
  void _clearModelSwitchMessages() {
    messages.removeWhere(
      (m) => m.role == MessageRole.system && m.text.startsWith(_modelSwitchPrefix),
    );
  }

  void _addSystemMessage(String text) {
    messages.add(ChatMessage(
      text: text,
      role: MessageRole.system,
      timestamp: DateTime.now(),
    ));
  }
}
