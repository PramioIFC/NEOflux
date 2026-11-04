import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scans the device for local audio files and integrates them into Flux.
class LocalFileScannerService {
  static const List<String> _supportedExtensions = [
    '.mp3', '.flac', '.m4a', '.aac', '.wav', '.ogg', '.opus', '.wma',
  ];

  /// Scan common music directories for audio files
  static Future<List<Map<String, String>>> scanForLocalFiles() async {
    final List<Map<String, String>> foundTracks = [];

    try {
      // Common Android music directories
      final directories = <Directory>[];

      if (Platform.isAndroid) {
        // External storage music paths
        final externalDirs = [
          Directory('/storage/emulated/0/Music'),
          Directory('/storage/emulated/0/Download'),
          Directory('/storage/emulated/0/Downloads'),
          Directory('/sdcard/Music'),
          Directory('/sdcard/Download'),
        ];

        for (final dir in externalDirs) {
          if (await dir.exists()) {
            directories.add(dir);
          }
        }

        // Also check app-specific external storage
        try {
          final extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            directories.add(extDir);
          }
        } catch (_) {}
      } else if (Platform.isIOS || Platform.isMacOS) {
        final docDir = await getApplicationDocumentsDirectory();
        directories.add(docDir);
      } else {
        // Windows/Linux
        final docDir = await getApplicationDocumentsDirectory();
        directories.add(docDir);

        // Also try common paths
        final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
        if (home.isNotEmpty) {
          final musicDir = Directory('$home/Music');
          if (await musicDir.exists()) directories.add(musicDir);
          final downloadsDir = Directory('$home/Downloads');
          if (await downloadsDir.exists()) directories.add(downloadsDir);
        }
      }

      // Scan all directories
      for (final dir in directories) {
        await _scanDirectory(dir, foundTracks);
      }
    } catch (e) {
      debugPrint("FLUX LOCAL: Error scanning for local files: $e");
    }

    return foundTracks;
  }

  static Future<void> _scanDirectory(
    Directory dir,
    List<Map<String, String>> results, {
    int maxDepth = 3,
    int currentDepth = 0,
  }) async {
    if (currentDepth >= maxDepth) return;

    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          final path = entity.path.toLowerCase();
          if (_supportedExtensions.any((ext) => path.endsWith(ext))) {
            final track = _extractMetadataFromPath(entity.path);
            results.add(track);
          }
        } else if (entity is Directory) {
          await _scanDirectory(entity, results, maxDepth: maxDepth, currentDepth: currentDepth + 1);
        }
      }
    } catch (e) {
      // Permission denied or other errors — skip this directory
      debugPrint("FLUX LOCAL: Skipping directory ${dir.path}: $e");
    }
  }

  /// Extract basic metadata from the file path
  static Map<String, String> _extractMetadataFromPath(String filePath) {
    final fileName = filePath.split(Platform.pathSeparator).last;
    // Remove extension
    final nameWithoutExt = fileName.replaceAll(RegExp(r'\.[^.]+$'), '');

    // Try to parse "Artist - Track Name" format
    String trackName = nameWithoutExt;
    String artist = 'Local File';

    if (nameWithoutExt.contains(' - ')) {
      final parts = nameWithoutExt.split(' - ');
      artist = parts[0].trim();
      trackName = parts.sublist(1).join(' - ').trim();
    } else if (nameWithoutExt.contains(' _ ')) {
      final parts = nameWithoutExt.split(' _ ');
      artist = parts[0].trim();
      trackName = parts.sublist(1).join(' _ ').trim();
    }

    return {
      'track_name': trackName,
      'artist': artist,
      'album_image_url': '',
      'video_id': '',
      'local_path': filePath,
      'is_local': 'true',
    };
  }

  /// Save discovered local files to preferences
  static Future<void> saveLocalLibrary(List<Map<String, String>> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_local_library', json.encode(tracks));
  }

  /// Load previously discovered local files
  static Future<List<Map<String, String>>> loadLocalLibrary() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('flux_local_library');
    if (data == null) return [];

    try {
      final decoded = json.decode(data) as List;
      return decoded.map((e) => Map<String, String>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }
}
