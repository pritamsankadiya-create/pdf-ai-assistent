import 'package:googleai_dart/googleai_dart.dart';

enum QueryComplexity { simple, complex }

class RouteResult {
  final String modelId;
  final QueryComplexity complexity;

  const RouteResult({required this.modelId, required this.complexity});
}

class ModelRouter {
  static const _triageModel = 'gemini-2.0-flash-lite';
  static const _simpleModel = 'gemini-2.0-flash-lite';
  static const _complexModel = 'gemini-2.5-pro-preview';

  final GoogleAIClient _client;

  ModelRouter(this._client);

  Future<RouteResult> routeRequest(String userQuery) async {
    try {
      final response = await _client.models.generateContent(
        model: _triageModel,
        request: GenerateContentRequest(
          contents: [Content.text(userQuery)],
          systemInstruction: Content(parts: [Part.text(_classificationPrompt)]),
          generationConfig: GenerationConfig(
            temperature: 0,
            maxOutputTokens: 10,
          ),
        ),
      );

      final result = (response.text ?? '').trim().toUpperCase();
      if (result.contains('COMPLEX')) {
        return const RouteResult(
          modelId: _complexModel,
          complexity: QueryComplexity.complex,
        );
      }
      return const RouteResult(
        modelId: _simpleModel,
        complexity: QueryComplexity.simple,
      );
    } catch (_) {
      // Fail-open: default to cheap model
      return const RouteResult(
        modelId: _simpleModel,
        complexity: QueryComplexity.simple,
      );
    }
  }

  static const _classificationPrompt =
      'Classify the user query as SIMPLE or COMPLEX.\n'
      'SIMPLE: definitions, single-fact lookups, yes/no questions, '
      'straightforward extraction from a document.\n'
      'COMPLEX: comparisons, multi-step reasoning, analysis, synthesis '
      'across multiple sections, or creative tasks.\n'
      'Respond with exactly one word: SIMPLE or COMPLEX.';
}
