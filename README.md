# PDF AI Assistant

A Flutter app that lets you chat with your documents using Google Gemini AI. Load PDFs, images, spreadsheets, or text files and ask questions — the app analyzes them and responds in real time.

## Features

- **Multi-file support** — Load PDFs, images (PNG, JPG, GIF, WebP, BMP), spreadsheets (CSV, XLS, XLSX), and text files (TXT, MD) simultaneously
- **Streaming responses** — AI answers appear in real time as they're generated
- **Smart model routing** — Simple questions use a cheap model (`gemini-2.0-flash-lite`), complex queries use a powerful one (`gemini-2.5-pro-preview`), saving costs without sacrificing quality
- **Semantic caching** — Repeated or similar questions are answered instantly from local cache (similarity >= 0.85)
- **File URI persistence** — Binary files are uploaded once to the Google Files API and reused via URI references, avoiding redundant uploads
- **Self-healing feedback** — If a response isn't helpful, tap the thumbs-down button to automatically re-generate with the Pro model and update the cache
- **On-device AI** — Optional Gemini Nano support for offline text analysis via platform channels
- **Automatic retry** — Rate-limited requests automatically switch between models with exponential backoff

## Architecture

```
User Query
  -> Cache lookup (similarity >= 0.85?)
     -> HIT: Return cached response instantly ($0.00)
     -> MISS:
        -> Triage via flash-lite ("SIMPLE" or "COMPLEX")
           -> SIMPLE: gemini-2.0-flash-lite (~1/10th cost)
           -> COMPLEX: gemini-2.5-pro-preview (highest quality)
        -> Files sent as URI references (not raw bytes)
        -> Response cached for future lookups
  -> User clicks "Not helpful"?
     -> Re-run with Pro model, update cache
```

### Project Structure

```
lib/
├── main.dart                          # App entry point, async Hive init
├── controllers/
│   └── chat_controller.dart           # State management (GetX), message handling, feedback loop
├── models/
│   ├── attached_file.dart             # File wrapper with type detection and text conversion
│   └── chat_message.dart              # Message model with metadata (modelUsed, fromCache, wasHelpful)
├── pages/
│   └── chat_page.dart                 # Main chat UI
├── services/
│   ├── ai_service.dart                # Central orchestration: cache -> route -> upload -> stream -> cache
│   ├── cache_service.dart             # Semantic cache (Hive + string similarity, 500 entries, 24h TTL)
│   ├── model_router.dart              # Query complexity classifier (SIMPLE/COMPLEX)
│   ├── file_upload_service.dart       # Google Files API upload with URI caching and expiry handling
│   └── local_ai_service.dart          # On-device Gemini Nano via platform channels
└── widgets/
    ├── message_bubble.dart            # Chat bubbles with model/cache labels and feedback button
    └── pdf_status_bar.dart            # File status indicator
```

### Cost Optimization

| Query Type | Model Used | Cost | Quality |
|-----------|-----------|------|---------|
| Repeated/similar | Cache | $0.00 | Same as original |
| Simple (definitions, lookups) | Flash-Lite | ~1/10th of Pro | High |
| Complex (analysis, comparison) | Pro | Standard | Highest |

## Getting Started

### Prerequisites

- Flutter SDK >= 3.9.2
- A [Google AI API key](https://aistudio.google.com/apikey)

### Run

```bash
flutter run --dart-define=GEMINI_API_KEY=your_api_key_here
```

### Build

```bash
# Android
flutter build apk --dart-define=GEMINI_API_KEY=your_api_key_here

# Web
flutter build web --dart-define=GEMINI_API_KEY=your_api_key_here
```

## Dependencies

| Package | Purpose |
|---------|---------|
| `googleai_dart` | Google Gemini API client |
| `hive_flutter` | Local key-value storage for semantic cache |
| `string_similarity` | Fuzzy query matching for cache lookups |
| `crypto` | SHA-256 file fingerprinting |
| `get` | State management and dependency injection |
| `file_picker` | File selection dialog |
| `excel` | Spreadsheet parsing (XLS/XLSX) |
