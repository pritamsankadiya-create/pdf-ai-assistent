import 'package:flutter/material.dart';
import 'package:get/get.dart';

// ── Chat feature imports (uncomment to restore ChatPage) ──
// import 'controllers/chat_controller.dart';
// import 'pages/chat_page.dart';
// import 'services/ai_service.dart';

import 'pages/audio_transcript_page.dart';

// ── Original main with Gemini API (uncomment to restore) ──
// Future<void> main() async {
//   WidgetsFlutterBinding.ensureInitialized();
//
//   const apiKey = String.fromEnvironment('GEMINI_API_KEY');
//   if (apiKey.isEmpty) {
//     throw StateError(
//       'GEMINI_API_KEY not set. '
//       'Run with: flutter run --dart-define=GEMINI_API_KEY=your_key',
//     );
//   }
//   await AIService.initialize(apiKey);
//   runApp(const MyApp());
// }

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PDF AI Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // ── Chat binding & page (uncomment to restore ChatPage) ──
      // initialBinding: BindingsBuilder(() {
      //   Get.put(ChatController());
      // }),
      // home: ChatPage(),

      home: const AudioTranscriptPage(),
    );
  }
}