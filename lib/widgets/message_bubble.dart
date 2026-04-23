import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final String? loadingStatus;
  final VoidCallback? onNotHelpful;

  const MessageBubble({
    super.key,
    required this.message,
    this.loadingStatus,
    this.onNotHelpful,
  });

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      MessageRole.system => _SystemBubble(message: message),
      MessageRole.user => _UserBubble(message: message),
      MessageRole.ai => _AiBubble(
          message: message,
          loadingStatus: loadingStatus,
          onNotHelpful: onNotHelpful,
        ),
    };
  }
}

class _UserBubble extends StatelessWidget {
  final ChatMessage message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          message.text,
          style: TextStyle(color: theme.colorScheme.onPrimary),
        ),
      ),
    );
  }
}

class _AiBubble extends StatelessWidget {
  final ChatMessage message;
  final String? loadingStatus;
  final VoidCallback? onNotHelpful;

  const _AiBubble({
    required this.message,
    this.loadingStatus,
    this.onNotHelpful,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLoading = message.text.isEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: isLoading
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  if (loadingStatus != null && loadingStatus!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      loadingStatus!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    message.text,
                    style: TextStyle(color: theme.colorScheme.onSurface),
                  ),
                  if (message.fromCache == true ||
                      message.modelUsed != null ||
                      (message.wasHelpful == null && message.text.isNotEmpty))
                    const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (message.fromCache == true)
                        _MetadataChip(label: 'cached', theme: theme),
                      if (message.modelUsed != null) ...[
                        if (message.fromCache == true)
                          const SizedBox(width: 6),
                        _MetadataChip(
                          label: message.modelUsed!,
                          theme: theme,
                        ),
                      ],
                      if (message.wasHelpful == null &&
                          message.text.isNotEmpty &&
                          onNotHelpful != null) ...[
                        const Spacer(),
                        InkWell(
                          onTap: onNotHelpful,
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.thumb_down_outlined,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      if (message.wasHelpful == false)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.thumb_down,
                            size: 16,
                            color: theme.colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _MetadataChip extends StatelessWidget {
  final String label;
  final ThemeData theme;

  const _MetadataChip({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SystemBubble extends StatelessWidget {
  final ChatMessage message;
  const _SystemBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          message.text,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.grey,
                fontStyle: FontStyle.italic,
              ),
        ),
      ),
    );
  }
}
