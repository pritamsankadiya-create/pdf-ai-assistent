import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:string_similarity/string_similarity.dart';

import '../models/attached_file.dart';

class CacheEntry {
  final String normalizedQuery;
  final String response;
  final String modelUsed;
  final String fileFingerprint;
  final DateTime timestamp;
  final bool wasHelpful;

  const CacheEntry({
    required this.normalizedQuery,
    required this.response,
    required this.modelUsed,
    required this.fileFingerprint,
    required this.timestamp,
    this.wasHelpful = true,
  });

  Map<String, dynamic> toMap() => {
    'normalizedQuery': normalizedQuery,
    'response': response,
    'modelUsed': modelUsed,
    'fileFingerprint': fileFingerprint,
    'timestamp': timestamp.toIso8601String(),
    'wasHelpful': wasHelpful,
  };

  factory CacheEntry.fromMap(Map<dynamic, dynamic> map) => CacheEntry(
    normalizedQuery: map['normalizedQuery'] as String,
    response: map['response'] as String,
    modelUsed: map['modelUsed'] as String,
    fileFingerprint: map['fileFingerprint'] as String,
    timestamp: DateTime.parse(map['timestamp'] as String),
    wasHelpful: map['wasHelpful'] as bool? ?? true,
  );
}

class CacheResult {
  final String response;
  final String modelUsed;

  const CacheResult({required this.response, required this.modelUsed});
}

class CacheService {
  static const _boxName = 'semantic_cache';
  static const _maxEntries = 500;
  static const _ttl = Duration(hours: 24);
  static const _similarityThreshold = 0.85;

  late Box<Map> _box;

  Future<void> initialize() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<Map>(_boxName);
    _evictExpired();
  }

  static String _normalize(String query) {
    return query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String generateFileFingerprint(List<AttachedFile> files) {
    final sorted = List<AttachedFile>.from(files)
      ..sort((a, b) => a.name.compareTo(b.name));
    final input = sorted.map((f) => '${f.name}:${f.bytes.length}').join('|');
    return sha256.convert(utf8.encode(input)).toString();
  }

  CacheResult? lookup(String query, String fileFingerprint) {
    final normalized = _normalize(query);
    CacheEntry? bestMatch;
    double bestScore = 0;

    for (final key in _box.keys) {
      final map = _box.get(key);
      if (map == null) continue;

      final entry = CacheEntry.fromMap(map);

      // Skip expired entries
      if (DateTime.now().difference(entry.timestamp) > _ttl) continue;

      // Skip entries marked unhelpful
      if (!entry.wasHelpful) continue;

      // Must match file fingerprint
      if (entry.fileFingerprint != fileFingerprint) continue;

      final score = StringSimilarity.compareTwoStrings(
        normalized,
        entry.normalizedQuery,
      );

      if (score > bestScore && score >= _similarityThreshold) {
        bestScore = score;
        bestMatch = entry;
      }
    }

    if (bestMatch == null) return null;
    return CacheResult(
      response: bestMatch.response,
      modelUsed: bestMatch.modelUsed,
    );
  }

  Future<void> store(CacheEntry entry) async {
    // LRU eviction if at capacity
    if (_box.length >= _maxEntries) {
      _evictOldest();
    }

    final key = '${entry.fileFingerprint}_${entry.normalizedQuery.hashCode}';
    await _box.put(key, entry.toMap());
  }

  Future<void> markUnhelpful(String query, String fileFingerprint) async {
    final normalized = _normalize(query);
    for (final key in _box.keys) {
      final map = _box.get(key);
      if (map == null) continue;

      final entry = CacheEntry.fromMap(map);
      if (entry.fileFingerprint != fileFingerprint &&
          entry.normalizedQuery == normalized) {
        continue;
      }

      final score = StringSimilarity.compareTwoStrings(
        normalized,
        entry.normalizedQuery,
      );
      if (score >= _similarityThreshold &&
          entry.fileFingerprint == fileFingerprint) {
        final updated = CacheEntry(
          normalizedQuery: entry.normalizedQuery,
          response: entry.response,
          modelUsed: entry.modelUsed,
          fileFingerprint: entry.fileFingerprint,
          timestamp: entry.timestamp,
          wasHelpful: false,
        );
        await _box.put(key, updated.toMap());
      }
    }
  }

  Future<void> updateResponse(
    String query,
    String fileFingerprint,
    String newResponse,
    String newModel,
  ) async {
    final normalized = _normalize(query);
    final key = '${fileFingerprint}_${normalized.hashCode}';
    final entry = CacheEntry(
      normalizedQuery: normalized,
      response: newResponse,
      modelUsed: newModel,
      fileFingerprint: fileFingerprint,
      timestamp: DateTime.now(),
      wasHelpful: true,
    );
    await _box.put(key, entry.toMap());
  }

  void _evictExpired() {
    final keysToDelete = <dynamic>[];
    for (final key in _box.keys) {
      final map = _box.get(key);
      if (map == null) continue;
      final entry = CacheEntry.fromMap(map);
      if (DateTime.now().difference(entry.timestamp) > _ttl) {
        keysToDelete.add(key);
      }
    }
    for (final key in keysToDelete) {
      _box.delete(key);
    }
  }

  void _evictOldest() {
    if (_box.isEmpty) return;

    // Find and remove the oldest 10% of entries
    final entries = <dynamic, DateTime>{};
    for (final key in _box.keys) {
      final map = _box.get(key);
      if (map == null) continue;
      entries[key] = CacheEntry.fromMap(map).timestamp;
    }

    final sorted = entries.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final removeCount = (_maxEntries * 0.1).ceil();
    for (var i = 0; i < removeCount && i < sorted.length; i++) {
      _box.delete(sorted[i].key);
    }
  }
}
