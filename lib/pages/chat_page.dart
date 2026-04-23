import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/chat_controller.dart';
import '../models/chat_message.dart';
import '../services/local_ai_service.dart';
import '../widgets/message_bubble.dart';
import '../widgets/pdf_status_bar.dart';

class ChatPage extends StatelessWidget {
  ChatPage({super.key});

  ChatController get _controller => Get.find<ChatController>();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSend() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    _textController.clear();
    _controller.sendMessage(text);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final names = _controller.fileNames.toList();
      final hasFiles = _controller.hasFiles;
      final loading = _controller.isLoading.value;
      final messageList = _controller.messages.toList();
      final status = _controller.loadingStatus.value;
      final isLocal = _controller.aiSource.value == AISource.local;
      final localStatus = _controller.localAIStatus.value;

      _scrollToBottom();

      return Scaffold(
        appBar: AppBar(
          title: Text(isLocal ? 'AI Assistant (Local)' : 'AI Assistant'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: Icon(isLocal ? Icons.smartphone : Icons.cloud),
              tooltip: isLocal ? 'Using on-device AI' : 'Using cloud AI',
              onPressed: _controller.toggleAISource,
            ),
          ],
        ),
        body: Column(
          children: [
            if (names.isNotEmpty) FileStatusBar(fileNames: names),
            if (isLocal && localStatus == LocalAIStatus.downloading)
              MaterialBanner(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                content: const Text(
                  'Local AI model is downloading. This may take a while. Cloud AI is available in the meantime.',
                ),
                actions: [
                  TextButton(
                    onPressed: () async {
                      final status = await LocalAIService.instance.checkStatus();
                      _controller.localAIStatus.value = status;
                    },
                    child: const Text('Refresh'),
                  ),
                ],
              ),
            if (isLocal && localStatus == LocalAIStatus.unavailable)
              MaterialBanner(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                leading: const Icon(Icons.info_outline, color: Colors.orange),
                content: Text(
                  'Local AI is not available: ${LocalAIService.instance.statusMessage}',
                ),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(top: 8, bottom: 8),
                    itemCount: messageList.length,
                    itemBuilder: (context, index) {
                      final msg = messageList[index];
                      final isLastAi = loading &&
                          index == messageList.length - 1 &&
                          msg.text.isEmpty;
                      return MessageBubble(
                        message: msg,
                        loadingStatus: isLastAi ? status : null,
                        onNotHelpful: msg.role == MessageRole.ai &&
                                msg.text.isNotEmpty &&
                                msg.wasHelpful == null &&
                                !loading
                            ? () => _controller.markNotHelpful(index)
                            : null,
                      );
                    },
                  ),
                  if (!hasFiles)
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: FloatingActionButton(
                        onPressed: _controller.pickFiles,
                        tooltip: 'Load files',
                        child: const Icon(Icons.attach_file),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    offset: const Offset(0, -1),
                    blurRadius: 4,
                    color: Colors.black12,
                  ),
                ],
              ),
              child: SafeArea(
                child: Row(
                  children: [
                    if (hasFiles)
                      IconButton(
                        icon: const Icon(Icons.attach_file),
                        onPressed: _controller.pickFiles,
                        tooltip: 'Change files',
                      ),
                    Expanded(
                      child: TextField(
                        controller: _textController,
                        enabled: (hasFiles || isLocal) && !loading,
                        decoration: InputDecoration(
                          hintText: isLocal
                              ? (hasFiles
                                  ? 'Ask about your files (local)...'
                                  : 'Ask anything (local)...')
                              : (hasFiles
                                  ? 'Ask about your files...'
                                  : 'Load files first'),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                        ),
                        textInputAction: TextInputAction.send,
                        onSubmitted:
                            (hasFiles || isLocal) && !loading
                                ? (_) => _handleSend()
                                : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed:
                          (hasFiles || isLocal) && !loading
                              ? _handleSend
                              : null,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    });
  }
}
