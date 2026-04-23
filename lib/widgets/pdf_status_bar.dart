import 'package:flutter/material.dart';

class FileStatusBar extends StatelessWidget {
  final List<String> fileNames;

  const FileStatusBar({super.key, required this.fileNames});

  IconData _iconForFile(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' => Icons.image,
      'csv' || 'xls' || 'xlsx' => Icons.table_chart,
      'txt' || 'md' => Icons.description,
      _ => Icons.insert_drive_file,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.secondaryContainer,
      child: Row(
        children: [
          if (fileNames.length == 1)
            Icon(
              _iconForFile(fileNames.first),
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            )
          else
            Icon(
              Icons.folder_open,
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              fileNames.length == 1
                  ? fileNames.first
                  : '${fileNames.length} files: ${fileNames.join(", ")}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
