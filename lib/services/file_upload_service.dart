import 'package:googleai_dart/googleai_dart.dart';

import '../models/attached_file.dart';

class UploadedFileRef {
  final String name;
  final String uri;
  final String mimeType;
  final DateTime expirationTime;

  const UploadedFileRef({
    required this.name,
    required this.uri,
    required this.mimeType,
    required this.expirationTime,
  });

  /// Whether this ref is still valid (30-min buffer before 48h expiry).
  bool get isValid =>
      DateTime.now().isBefore(expirationTime.subtract(const Duration(minutes: 30)));
}

class FileUploadService {
  final GoogleAIClient _client;

  /// Key: "fileName:byteLength" → UploadedFileRef
  final Map<String, UploadedFileRef> _cache = {};

  FileUploadService(this._client);

  String _cacheKey(AttachedFile file) => '${file.name}:${file.bytes.length}';

  /// Returns a cached upload ref if valid, or null.
  UploadedFileRef? getCachedRef(AttachedFile file) {
    final ref = _cache[_cacheKey(file)];
    return (ref != null && ref.isValid) ? ref : null;
  }

  /// Ensures a single binary file is uploaded and returns its ref.
  Future<UploadedFileRef> ensureUploaded(AttachedFile file) async {
    final key = _cacheKey(file);
    final existing = _cache[key];
    if (existing != null && existing.isValid) {
      return existing;
    }

    final uploaded = await _client.files.upload(
      bytes: file.bytes,
      fileName: file.name,
      mimeType: file.mimeType,
    );

    // Poll until active (max ~60s)
    var fileInfo = uploaded;
    var attempts = 0;
    while (fileInfo.state == FileState.processing && attempts < 30) {
      await Future.delayed(const Duration(seconds: 2));
      fileInfo = await _client.files.get(name: fileInfo.name);
      attempts++;
    }

    if (fileInfo.state == FileState.failed) {
      throw Exception('File upload failed for ${file.name}');
    }

    final ref = UploadedFileRef(
      name: fileInfo.name,
      uri: fileInfo.uri,
      mimeType: fileInfo.mimeType,
      expirationTime: fileInfo.expirationTime,
    );

    _cache[key] = ref;
    return ref;
  }

  /// Uploads all binary files (PDFs, images). Text files are skipped.
  Future<List<UploadedFileRef>> ensureAllUploaded(
    List<AttachedFile> files,
  ) async {
    final binaryFiles = files.where((f) => !f.needsTextConversion).toList();
    final refs = <UploadedFileRef>[];
    for (final file in binaryFiles) {
      refs.add(await ensureUploaded(file));
    }
    return refs;
  }

  /// Clears all cached upload refs (call when user picks new files).
  void clearAll() {
    _cache.clear();
  }
}
