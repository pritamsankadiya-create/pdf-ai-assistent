import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';

class AttachedFile {
  final String name;
  final String mimeType;
  final Uint8List bytes;

  const AttachedFile({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  String get extension => name.split('.').last.toLowerCase();

  /// Whether this file can be processed by local/on-device AI (text-based only).
  bool get isLocalAICompatible => needsTextConversion;

  /// Whether this file needs to be converted to text before sending to Gemini.
  bool get needsTextConversion {
    return switch (extension) {
      'csv' || 'xls' || 'xlsx' || 'txt' || 'md' => true,
      _ => false,
    };
  }

  /// Converts spreadsheet/text files to a text representation for Gemini.
  String toTextContent() {
    return switch (extension) {
      'xls' || 'xlsx' => _excelToText(),
      'csv' || 'txt' || 'md' => utf8.decode(bytes, allowMalformed: true),
      _ => '',
    };
  }

  String _excelToText() {
    final excel = Excel.decodeBytes(bytes);
    final buffer = StringBuffer();

    for (final sheetName in excel.tables.keys) {
      final sheet = excel.tables[sheetName]!;
      buffer.writeln('=== Sheet: $sheetName ===');

      for (final row in sheet.rows) {
        final cells = row.map((cell) => cell?.value?.toString() ?? '').toList();
        buffer.writeln(cells.join('\t'));
      }
      buffer.writeln();
    }

    return buffer.toString();
  }

  static String mimeTypeFromExtension(String ext) {
    return switch (ext.toLowerCase()) {
      'pdf' => 'application/pdf',
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'csv' => 'text/csv',
      'xls' => 'application/vnd.ms-excel',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'txt' => 'text/plain',
      'md' => 'text/markdown',
      _ => 'application/octet-stream',
    };
  }

  static const supportedExtensions = [
    'pdf',
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp',
    'csv', 'xls', 'xlsx',
    'txt', 'md',
  ];
}
