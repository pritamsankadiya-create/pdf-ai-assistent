enum MessageRole { user, ai, system }

class ChatMessage {
  final String text;
  final MessageRole role;
  final DateTime timestamp;
  final String? modelUsed;
  final bool? fromCache;
  final bool? wasHelpful;
  final String? originalQuery;

  const ChatMessage({
    required this.text,
    required this.role,
    required this.timestamp,
    this.modelUsed,
    this.fromCache,
    this.wasHelpful,
    this.originalQuery,
  });

  ChatMessage copyWith({
    String? text,
    MessageRole? role,
    DateTime? timestamp,
    String? modelUsed,
    bool? fromCache,
    bool? wasHelpful,
    String? originalQuery,
  }) {
    return ChatMessage(
      text: text ?? this.text,
      role: role ?? this.role,
      timestamp: timestamp ?? this.timestamp,
      modelUsed: modelUsed ?? this.modelUsed,
      fromCache: fromCache ?? this.fromCache,
      wasHelpful: wasHelpful ?? this.wasHelpful,
      originalQuery: originalQuery ?? this.originalQuery,
    );
  }
}
