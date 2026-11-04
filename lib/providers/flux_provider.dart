import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:just_audio_background/just_audio_background.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/listening_history_service.dart';
import '../services/equalizer_service.dart';

enum PlaybackRepeatMode { off, all, one }

class FluxProvider extends ChangeNotifier {
  late final AudioPlayer player;
  AndroidEqualizer? androidEqualizer;

  String baseUrl = "";

  // --- DOWNLOAD QUEUE ---
  final Queue<Map<String, String>> _downloadQueue = Queue();
  final Set<String> _activeDownloads = {};
  final Map<String, ValueNotifier<double>> _progressNotifiers = {};
  final Map<String, Completer<bool>> _downloadCompleters = {};
  final int _maxConcurrent = 1;
  final Map<String, String> _trackStatuses = {};

  String _downloadKey(Map<String, String> track) =>
      '${track['track_name']?.trim() ?? ''}||${track['artist']?.trim() ?? ''}';

  ValueNotifier<double>? getProgress(Map<String, String> track) =>
      _progressNotifiers[_downloadKey(track)];
  String getTrackStatus(Map<String, String> track) =>
      _trackStatuses[_downloadKey(track)] ?? "NONE";

  // --- SLEEP TIMER ---
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndTime;

  DateTime? get sleepTimerEndTime => _sleepTimerEndTime;

  void startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();
    _sleepTimerEndTime = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      player.stop();
      _sleepTimerEndTime = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndTime = null;
    notifyListeners();
  }

  // --- CORE STATE ---
  Map<String, String>? currentTrack;
  List<Map<String, String>> currentQueue = [];
  Map<String, List<Map<String, String>>> playlists = {"Favoritas": []};
  
  // --- USER PROFILE ---
  String username = "";
  bool isPublic = false;
  List<String> friends = [];
  
  // --- SETTINGS ---
  bool _showTrending = true;
  bool get showTrending => _showTrending;

  String _audioQuality = 'normal';
  String get audioQuality => _audioQuality;

  
  Color dominantColor = const Color(0xFF1DB954);

  Future<void> _updatePalette(String? imageUrl) async {
    if (imageUrl == null || imageUrl.isEmpty) {
      dominantColor = const Color(0xFF1DB954);
      notifyListeners();
      return;
    }
    try {
      final PaletteGenerator palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(imageUrl),
      );
      dominantColor = palette.dominantColor?.color ?? palette.vibrantColor?.color ?? const Color(0xFF1DB954);
      notifyListeners();
    } catch (e) {
      dominantColor = const Color(0xFF1DB954);
      notifyListeners();
    }
  }

  // --- RECENTLY PLAYED ---
  List<Map<String, String>> _recentlyPlayed = [];
  List<Map<String, String>> get recentlyPlayed => List.unmodifiable(_recentlyPlayed);

  // --- PER-PLAYLIST SHUFFLE MODE ---
  Map<String, bool> _playlistShuffleMode = {};

  // --- CUSTOM PLAYLIST COVERS ---
  Map<String, String> _playlistCovers = {};

  bool _playerListenerRegistered = false;
  EqualizerService? _eqService;

  void attachEqualizerService(EqualizerService eqService) {
    if (_eqService == eqService) return;
    
    _eqService?.removeListener(_applyEqualizerSettings);
    _eqService = eqService;
    _eqService?.addListener(_applyEqualizerSettings);
    
    _applyEqualizerSettings();
  }

  Future<void> _applyEqualizerSettings() async {
    if (androidEqualizer == null || _eqService == null) return;
    try {
      final parameters = await androidEqualizer!.parameters;
      await androidEqualizer!.setEnabled(_eqService!.isEnabled);
      
      final bands = _eqService!.currentBands;
      for (int i = 0; i < bands.length && i < parameters.bands.length; i++) {
        await parameters.bands[i].setGain(bands[i]);
      }
    } catch (e) {
      debugPrint("FLUX EQ ERROR: $e");
    }
  }

  FluxProvider() {
    if (!kIsWeb && Platform.isAndroid) {
      androidEqualizer = AndroidEqualizer();
      player = AudioPlayer(
        audioPipeline: AudioPipeline(androidAudioEffects: [androidEqualizer!]),
      );
    } else {
      player = AudioPlayer();
    }

    _loadFromPrefs();

    _loadPlaylistCovers();
    _registerPlayerListener();
  }

  void _registerPlayerListener() {
    if (_playerListenerRegistered) return;
    _playerListenerRegistered = true;
    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (_repeatMode != PlaybackRepeatMode.one) {
          skipNext();
        } else {
          player.seek(Duration.zero);
          player.play();
        }
      }
    });

    player.sequenceStateStream.listen((sequenceState) {
      if (sequenceState == null || sequenceState.currentSource == null) return;
      
      final currentItem = sequenceState.currentSource!.tag as MediaItem?;
      if (currentItem != null) {
        debugPrint("FLUX EVENT: sequenceStateStream fired. Current Item from tag is: ${currentItem.title}");
        final newTrack = {
          'video_id': currentItem.id,
          'track_name': currentItem.title,
          'artist': currentItem.artist ?? 'Artista Desconhecido',
          'album_image_url': currentItem.artUri?.toString() ?? '',
        };

        final isSameTrack = currentTrack != null && 
                            currentTrack!['track_name'] == newTrack['track_name'] && 
                            currentTrack!['artist'] == newTrack['artist'];
        
        if (!isSameTrack) {
          debugPrint("FLUX EVENT: sequenceStateStream fired. Updating currentTrack to ${newTrack['track_name']}");
          
          // The notification is perfectly in sync because it uses the MediaItem tag.
          // We must use the exact same data to guarantee the UI is in sync.
          currentTrack = newTrack;
          
          final index = sequenceState.currentIndex;
          if (index != null && index >= 0 && index < currentQueue.length) {
             _preloadNextTracks(index);
          }
          
          _addToRecentlyPlayed(currentTrack!);
          _updatePalette(currentTrack!['album_image_url']);
          // Log listening history and broadcast to friends
          ListeningHistoryService.logListen(currentTrack!);
          ListeningHistoryService.broadcastNowPlaying(currentTrack!);
          notifyListeners();
        } else {
          // Apenas garanta que a UI atualize caso algo mais tenha mudado (ex: isPlaying state não pegou)
          notifyListeners();
        }
      }
    });
  }

  // --- RECENTLY PLAYED ---
  void _addToRecentlyPlayed(Map<String, String> track) {
    _recentlyPlayed.removeWhere(
      (t) =>
          t['track_name'] == track['track_name'] &&
          t['artist'] == track['artist'],
    );
    _recentlyPlayed.insert(0, Map<String, String>.from(track));
    if (_recentlyPlayed.length > 20) {
      _recentlyPlayed = _recentlyPlayed.sublist(0, 20);
    }
    _saveRecentlyPlayed();
    notifyListeners();
  }

  Future<void> _saveRecentlyPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_recently_played', json.encode(_recentlyPlayed));
  }

  Future<void> _loadRecentlyPlayed() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('flux_recently_played');
    if (savedData != null) {
      try {
        final List<dynamic> decoded = json.decode(savedData);
        _recentlyPlayed =
            decoded.map((item) => Map<String, String>.from(item)).toList();
      } catch (e) {
        debugPrint("Erro ao carregar recentes: $e");
      }
    }
  }

  // --- SHUFFLE MODE ---
  bool isPlaylistShuffled(String name) => _playlistShuffleMode[name] ?? true;

  void togglePlaylistShuffle(String name) {
    _playlistShuffleMode[name] = !isPlaylistShuffled(name);
    _saveShuffleMode();
    notifyListeners();
  }

  void setPlaylistShuffle(String name, bool shuffle) {
    _playlistShuffleMode[name] = shuffle;
    _saveShuffleMode();
    notifyListeners();
  }

  Future<void> _saveShuffleMode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'flux_shuffle_mode', json.encode(_playlistShuffleMode));
  }

  Future<void> _loadShuffleMode() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('flux_shuffle_mode');
    if (savedData != null) {
      try {
        final Map<String, dynamic> decoded = json.decode(savedData);
        _playlistShuffleMode =
            decoded.map((k, v) => MapEntry(k, v as bool));
      } catch (e) {
        debugPrint("Erro ao carregar shuffle mode: $e");
      }
    }
  }

  // --- PLAYLIST COVERS ---
  String? getPlaylistCover(String playlistName) {
    // Custom cover first, then fall back to first track's album art
    if (_playlistCovers.containsKey(playlistName) && _playlistCovers[playlistName]!.isNotEmpty) {
      return _playlistCovers[playlistName];
    }
    // Fallback: first track's album art
    final tracks = playlists[playlistName];
    if (tracks != null && tracks.isNotEmpty) {
      final url = tracks.first['album_image_url'];
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  void setPlaylistCover(String playlistName, String imageUrl) {
    _playlistCovers[playlistName] = imageUrl;
    _savePlaylistCovers();
    notifyListeners();
  }

  void removePlaylistCover(String playlistName) {
    _playlistCovers.remove(playlistName);
    _savePlaylistCovers();
    notifyListeners();
  }

  Future<void> _savePlaylistCovers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_playlist_covers', json.encode(_playlistCovers));
  }

  Future<void> _loadPlaylistCovers() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('flux_playlist_covers');
    if (savedData != null) {
      try {
        final Map<String, dynamic> decoded = json.decode(savedData);
        _playlistCovers = decoded.map((k, v) => MapEntry(k, v.toString()));
      } catch (e) {
        debugPrint("Erro ao carregar capas: $e");
      }
    }
  }

  // --- PINNED PLAYLISTS ---
  List<String> _pinnedPlaylists = [];
  bool isPinned(String name) => _pinnedPlaylists.contains(name);

  void togglePin(String name) {
    if (_pinnedPlaylists.contains(name)) {
      _pinnedPlaylists.remove(name);
    } else {
      _pinnedPlaylists.add(name);
    }
    _savePinnedPlaylists();
    notifyListeners();
  }

  Future<void> _savePinnedPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_pinned_playlists', json.encode(_pinnedPlaylists));
  }

  Future<void> _loadPinnedPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final String? savedData = prefs.getString('flux_pinned_playlists');
    if (savedData != null) {
      try {
        final List<dynamic> decoded = json.decode(savedData);
        _pinnedPlaylists = decoded.map((e) => e.toString()).toList();
      } catch (e) {
        debugPrint("Erro ao carregar pinned: \$e");
      }
    }
  }

  // --- ARTIST HELPERS ---
  /// Returns all unique artists across all playlists, sorted by track count desc
  List<MapEntry<String, int>> getAllArtistsSorted() {
    Map<String, int> artistCount = {};
    for (var list in playlists.values) {
      for (var track in list) {
        String artist = track['artist'] ?? 'Desconhecido';
        artistCount[artist] = (artistCount[artist] ?? 0) + 1;
      }
    }
    var sorted = artistCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted;
  }

  /// Returns all unique tracks by a given artist across all playlists
  List<Map<String, String>> getTracksForArtist(String artist) {
    final Set<String> seen = {};
    final List<Map<String, String>> result = [];
    for (var list in playlists.values) {
      for (var track in list) {
        if (track['artist'] == artist) {
          final key = '${track['track_name']}||${track['artist']}';
          if (!seen.contains(key)) {
            seen.add(key);
            result.add(Map<String, String>.from(track));
          }
        }
      }
    }
    return result;
  }

  /// Returns the album image URL for the artist's most common track
  String? getArtistImageUrl(String artist) {
    for (var list in playlists.values) {
      for (var track in list) {
        if (track['artist'] == artist) {
          final url = track['album_image_url'];
          if (url != null && url.isNotEmpty) return url;
        }
      }
    }
    return null;
  }

  // --- PERSISTENCE ---
  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = json.encode(playlists);
    await prefs.setString('flux_data', jsonString);
    
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      try {
        await Supabase.instance.client.from('user_data').upsert({
          'user_id': user.id,
          'playlists_json': json.decode(jsonString),
          'username': username,
          'is_public': isPublic,
          'friends': friends,
        }, onConflict: 'user_id');
      } catch (e) {
        debugPrint("FLUX: Error syncing to Supabase: $e");
      }
    }
  }

  Future<bool> enqueueDownload(Map<String, String> track) async {
    final downloadKey = _downloadKey(track);
    if (await isTrackDownloaded(track)) {
      _trackStatuses[downloadKey] = "DOWNLOADED";
      notifyListeners();
      return true;
    }

    final existingDownload = _downloadCompleters[downloadKey];
    if (existingDownload != null) return existingDownload.future;

    final completer = Completer<bool>();
    _downloadCompleters[downloadKey] = completer;
    _trackStatuses[downloadKey] = "QUEUED";
    notifyListeners();

    final videoId = await _resolveVideoId(track);
    if (videoId == null) {
      _trackStatuses[downloadKey] = "FAILED";
      _downloadCompleters.remove(downloadKey);
      completer.complete(false);
      notifyListeners();
      return completer.future;
    }

    _downloadQueue.add(track);
    _processNextDownload();
    return completer.future;
  }

  Future<void> _processNextDownload() async {
    if (_activeDownloads.length >= _maxConcurrent || _downloadQueue.isEmpty) {
      return;
    }

    final track = _downloadQueue.removeFirst();
    final videoId = track['video_id']!;
    final downloadKey = _downloadKey(track);

    _activeDownloads.add(videoId);
    _trackStatuses[downloadKey] = "DOWNLOADING";
    _progressNotifiers[downloadKey] = ValueNotifier(0.0);
    notifyListeners();

    var succeeded = false;
    try {
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await _executeDownload(track, videoId);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
          if (attempt < 3) {
            await Future<void>.delayed(Duration(seconds: attempt * 2));
          }
        }
      }
      if (lastError != null) throw lastError;
      _trackStatuses[downloadKey] = "DOWNLOADED";
      succeeded = true;
    } catch (e) {
      _trackStatuses[downloadKey] = "FAILED";
      debugPrint("Erro no download: $e");
    } finally {
      _activeDownloads.remove(videoId);
      _progressNotifiers[downloadKey]?.dispose();
      _progressNotifiers.remove(downloadKey);
      final completer = _downloadCompleters.remove(downloadKey);
      if (completer != null && !completer.isCompleted) {
        completer.complete(succeeded);
      }
      notifyListeners();
      _processNextDownload();
    }
  }

  Future<void> _executeDownload(
      Map<String, String> track, String videoId) async {
    final savePath = await getDownloadedAudioPath(track);
    final file = File(savePath);
    final partialFile = File('$savePath.part');

    if (await partialFile.exists()) {
      await partialFile.delete();
    }

    final streamUrl =
        "$baseUrl/stream_audio?id=$videoId&quality=$_audioQuality";
    final request = http.Request('GET', Uri.parse(streamUrl));
    request.headers['ngrok-skip-browser-warning'] = 'true';

    final response = await http.Client().send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception("Servidor retornou HTTP ${response.statusCode}");
    }
    final total = response.contentLength ?? 0;
    int received = 0;

    try {
      final sink = partialFile.openWrite();
      try {
        await for (var chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _progressNotifiers[_downloadKey(track)]?.value = received / total;
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total <= 0 || received != total) {
        throw Exception(
          "Download incompleto: recebido $received de $total bytes",
        );
      }

      if (await file.exists()) {
        await file.delete();
      }
      await partialFile.rename(savePath);
    } catch (_) {
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      rethrow;
    }
  }

  // --- IMPORT PLAYLIST ---
  Future<void> importPlaylistFromJson(
    String playlistName,
    List<dynamic> jsonList,
  ) async {
    if (!playlists.containsKey(playlistName)) {
      playlists[playlistName] = [];
    }

    for (var item in jsonList) {
      playlists[playlistName]!.add({
        "track_name": item["track_name"]?.toString() ?? "Unknown",
        "artist": item["artist"]?.toString() ?? "Unknown",
        "album_image_url": item["album_image_url"]?.toString() ?? "",
        "video_id": item["video_id"]?.toString() ?? "",
      });
    }

    await saveToPrefs();
    notifyListeners();
  }



  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final user = Supabase.instance.client.auth.currentUser;

    String? savedData;

    if (user != null) {
      try {
        final response = await Supabase.instance.client
            .from('user_data')
            .select('playlists_json, username, is_public, friends')
            .eq('user_id', user.id)
            .maybeSingle();
        
        if (response != null) {
          if (response['playlists_json'] != null) {
            savedData = json.encode(response['playlists_json']);
            await prefs.setString('flux_data', savedData);
          }
          username = response['username']?.toString() ?? "";
          isPublic = response['is_public'] ?? false;
          final friendsData = response['friends'];
          if (friendsData != null && friendsData is List) {
            friends = List<String>.from(friendsData);
          }
        }
      } catch (e) {
        debugPrint("FLUX: Error fetching from Supabase: $e");
      }
    }

    if (savedData == null) {
      savedData = prefs.getString('flux_data');
    }

    if (savedData != null) {
      try {
        Map<String, dynamic> decoded = json.decode(savedData);
        playlists = decoded.map((key, value) {
          return MapEntry(
            key,
            (value as List)
                .map((item) => Map<String, String>.from(item))
                .toList(),
          );
        });
      } catch (e) {
        debugPrint("Erro ao carregar dados: $e");
      }
    }
    
    baseUrl = prefs.getString('flux_server_url') ?? "";
    _audioQuality = prefs.getString('flux_audio_quality') ?? 'normal';
    _showTrending = prefs.getBool('flux_show_trending') ?? true;
    
    await _loadRecentlyPlayed();
    await _loadShuffleMode();
    await _loadPinnedPlaylists();
    notifyListeners();
  }

  Future<void> setAudioQuality(String quality) async {
    _audioQuality = quality;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_audio_quality', quality);
    notifyListeners();
  }

  Future<void> setBaseUrl(String url) async {
    baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('flux_server_url', url);
    notifyListeners();
  }

  Future<void> toggleShowTrending(bool value) async {
    _showTrending = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('flux_show_trending', value);
    notifyListeners();
  }

  Future<void> updateUsername(String newUsername) async {
    username = newUsername;
    await saveToPrefs();
    notifyListeners();
  }

  Future<void> toggleIsPublic(bool value) async {
    isPublic = value;
    await saveToPrefs();
    notifyListeners();
  }

  Future<void> toggleFriend(String friendId) async {
    if (friends.contains(friendId)) {
      friends.remove(friendId);
    } else {
      friends.add(friendId);
    }
    await saveToPrefs();
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> searchUsers(String query) async {
    if (query.isEmpty) return [];
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return [];
      final response = await Supabase.instance.client
          .rpc('search_users', params: {'query_text': query});
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint("Error searching users: $e");
      return [];
    }
  }

  Future<Map<String, dynamic>?> getFriendData(String friendId) async {
    try {
      final response = await Supabase.instance.client
          .rpc('get_friend_profile', params: {'friend_uid': friendId});
      if (response == null) return null;
      return Map<String, dynamic>.from(response);
    } catch (e) {
      debugPrint("Error getting friend data: $e");
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getFriendsList() async {
    if (friends.isEmpty) return [];
    try {
      final response = await Supabase.instance.client
          .rpc('get_friends_list', params: {'friend_ids': friends});
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint("Error fetching friends list: $e");
      return [];
    }
  }

  // --- FILE SYSTEM PATHS (native only) ---
  Future<String> getDownloadedAudioPath(Map<String, String> track) async {
    if (kIsWeb) return "";

    Directory? directory;

    if (Platform.isAndroid) {
      directory = await getExternalStorageDirectory();
    } else {
      directory = await getApplicationDocumentsDirectory();
    }

    directory ??= await getApplicationDocumentsDirectory();

    final safeTrackName = (track['track_name'] ?? 'track').replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '',
    );
    final safeArtist = (track['artist'] ?? 'artist').replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '',
    );

    return '${directory.path}/$safeTrackName - $safeArtist.mp3';
  }

  Future<bool> isTrackDownloaded(Map<String, String> track) async {
    if (kIsWeb) return false;
    final localPath = await getDownloadedAudioPath(track);
    final file = File(localPath);
    return await file.exists() && await file.length() > 0;
  }

  Future<void> deleteDownloadedTrack(Map<String, String> track) async {
    if (kIsWeb) return;
    try {
      final localPath = await getDownloadedAudioPath(track);
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
        _trackStatuses[_downloadKey(track)] = "NONE";
        notifyListeners();
      }
      final partialFile = File('$localPath.part');
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
    } catch (e) {
      debugPrint("Error deleting track: $e");
    }
  }

  // --- PLAYLIST MANAGEMENT ---
  void createPlaylist(String name) {
    if (name.isNotEmpty && !playlists.containsKey(name)) {
      playlists[name] = [];
      saveToPrefs();
      notifyListeners();
    }
  }

  void importPlaylistsData(Map<String, List<Map<String, String>>> data) {
    data.forEach((key, value) {
      playlists[key] = value;
    });
    saveToPrefs();
    notifyListeners();
  }


  void addTrackToPlaylist(String playlistName, Map<String, String> track) {
    if (playlists.containsKey(playlistName)) {
      bool exists = playlists[playlistName]!.any(
        (m) =>
            m["track_name"] == track["track_name"] &&
            m["artist"] == track["artist"],
      );
      if (!exists) {
        playlists[playlistName]!.add(Map<String, String>.from(track));
        saveToPrefs();
        notifyListeners();
      }
    }
  }

  void removeFromPlaylist(String playlistName, Map<String, String> track) {
    if (playlists.containsKey(playlistName)) {
      playlists[playlistName]!.removeWhere(
        (m) =>
            m["track_name"] == track["track_name"] &&
            m["artist"] == track["artist"],
      );
      saveToPrefs();
      notifyListeners();
    }
  }

  void deletePlaylist(String playlistName) {
    if (playlists.containsKey(playlistName)) {
      playlists.remove(playlistName);
      _playlistShuffleMode.remove(playlistName);
      _playlistCovers.remove(playlistName);
      _savePlaylistCovers();
      saveToPrefs();
      _saveShuffleMode();
      notifyListeners();
    }
  }

  void renamePlaylist(String oldName, String newName) {
    if (newName.isEmpty || playlists.containsKey(newName) || !playlists.containsKey(oldName)) return;
    playlists[newName] = List.from(playlists[oldName]!);
    playlists.remove(oldName);
    // Transfer shuffle mode
    if (_playlistShuffleMode.containsKey(oldName)) {
      _playlistShuffleMode[newName] = _playlistShuffleMode[oldName]!;
      _playlistShuffleMode.remove(oldName);
      _saveShuffleMode();
    }
    // Transfer cover
    if (_playlistCovers.containsKey(oldName)) {
      _playlistCovers[newName] = _playlistCovers[oldName]!;
      _playlistCovers.remove(oldName);
      _savePlaylistCovers();
    }
    saveToPrefs();
    notifyListeners();
  }

  void addToPlaylist(String playlistName, Video video) {
    if (playlists.containsKey(playlistName)) {
      final musicData = {
        "track_name": video.title,
        "artist": video.author,
        "album_image_url": video.thumbnails.lowResUrl,
        "video_id": video.id.value,
      };

      bool exists = playlists[playlistName]!.any(
        (m) => m["video_id"] == video.id.value,
      );

      if (!exists) {
        playlists[playlistName]!.add(musicData);
        saveToPrefs();
        notifyListeners();
      }
    }
  }

  // --- DOWNLOAD LOGIC (native only) ---
  Future<bool> downloadTrack(Map<String, String> track) async {
    if (kIsWeb) return false;
    return enqueueDownload(track);
  }

  Future<bool> downloadEntirePlaylist(String playlistName) async {
    if (kIsWeb) return false;
    if (!playlists.containsKey(playlistName)) return false;

    final tracks = List<Map<String, String>>.from(playlists[playlistName]!);
    final int total = tracks.length;
    int completed = 0;
    int failed = 0;

    debugPrint("FLUX: Starting download of '$playlistName' ($total tracks)");

    const int batchSize = 5;

    for (int i = 0; i < total; i += batchSize) {
      final end = (i + batchSize < total) ? i + batchSize : total;
      final batch = tracks.sublist(i, end);

      await Future.wait(
        batch.map((track) async {
          final success = await downloadTrack(track);
          if (!success) failed++;
          completed++;
          debugPrint("FLUX: Download progress $completed/$total");
        }),
      );
    }

    debugPrint(
      "FLUX: Download of '$playlistName' complete ($failed failures).",
    );
    return failed == 0;
  }

  // --- THE CORE PLAYBACK ENGINE ---

  Future<String?> _resolveVideoId(Map<String, String> track) async {
    String? videoId = track['video_id'];
    if (videoId != null && videoId.isNotEmpty) return videoId;

    final trackName = track['track_name']?.trim() ?? '';
    if (trackName.isEmpty) {
      debugPrint('FLUX: Ignorando faixa importada sem nome.');
      return null;
    }

    if (baseUrl.isEmpty) {
      debugPrint("FLUX: baseUrl is empty. Configure o servidor para buscar IDs.");
      return null;
    }

    debugPrint("FLUX: Missing video_id. Searching using Python backend...");
    try {
      final query = "$trackName ${track['artist'] ?? ''} audio";
      final searchUrl = "$baseUrl/search?q=${Uri.encodeComponent(query)}";
      final response = await http.get(
        Uri.parse(searchUrl),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        videoId = data['video_id']?.toString();
        if (videoId != null) {
           track['video_id'] = videoId;
           saveToPrefs();
        }
      } else {
        debugPrint("FLUX: Backend search returned status code ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("FLUX: Backend search error: $e");
    }
    return videoId;
  }

  Future<String?> _fetchStreamUrl(String videoId) async {
    if (baseUrl.isEmpty) {
      debugPrint("FLUX: baseUrl is empty. Configure o servidor.");
      return null;
    }
    
    try {
      final serverUrl = "$baseUrl/get_audio?id=$videoId&quality=$_audioQuality";
      final response = await http.get(
        Uri.parse(serverUrl),
        headers: {'ngrok-skip-browser-warning': 'true'},
      );
      
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['url']?.toString();
      } else {
        debugPrint("FLUX: Server returned status code ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("FLUX: Error fetching from Python server: $e");
    }
    return null;
  }

  ConcatenatingAudioSource? _queueSource;

  Future<void> _playFromQueueIndex(int index) async {
    if (index < 0 || index >= currentQueue.length) return;

    final children = <AudioSource>[];
    for (var track in currentQueue) {
      AudioSource? source;
      if (!kIsWeb) {
        final localPath = await getDownloadedAudioPath(track);
        // We do a sync check if we can, but exists() is async. 
        // A better approach is to assume StreamAudioSource and fallback, or just do the exists check.
        // For performance, we'll just use FluxStreamAudioSource which handles local paths too if we make it smart!
        // Actually, let's just use FluxStreamAudioSource for remote, and check file existence inside it!
      }
      children.add(FluxStreamAudioSource(track, this, tag: _createMediaItem(track)));
    }

    _queueSource = ConcatenatingAudioSource(children: children);

    currentTrack = currentQueue[index];
    _addToRecentlyPlayed(currentTrack!);
    _updatePalette(currentTrack!['album_image_url']);
    notifyListeners();

    try {
      await player.stop();
      await player.setAudioSource(_queueSource!, initialIndex: index);
      player.play();
    } catch (e) {
      debugPrint("FLUX ENGINE ERROR: $e");
    }

    _preloadNextTracks(index);
  }

  Future<void> _preloadNextTracks(int currentIndex) async {
    if (kIsWeb) return;

    // Use the same download queue as manual/playlist downloads. A separate
    // pre-cache transfer could delete or overwrite the same .part file.
    for (int i = 1; i <= 2; i++) {
      int nextIndex = currentIndex + i;
      if (nextIndex < currentQueue.length) {
        final track = currentQueue[nextIndex];

        if (await isTrackDownloaded(track)) continue;
        final status = getTrackStatus(track);
        if (status == "QUEUED" ||
            status == "DOWNLOADING" ||
            status == "DOWNLOADED") {
          continue;
        }

        debugPrint("FLUX CACHE: Pre-caching next track: ${track['track_name']}");
        final success = await enqueueDownload(track);
        if (success) {
          debugPrint("FLUX CACHE: Pre-cached successfully: ${track['track_name']}");
        } else {
          debugPrint("FLUX CACHE: Pre-cache failed for ${track['track_name']}");
        }
      }
    }
  }

  // --- QUEUE MANAGEMENT ---
  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= currentQueue.length) return;
    if (newIndex < 0 || newIndex > currentQueue.length) return;

    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    // Move in local list
    final track = currentQueue.removeAt(oldIndex);
    currentQueue.insert(newIndex, track);

    // Move in just_audio source
    if (_queueSource != null) {
      try {
        await _queueSource!.move(oldIndex, newIndex);
      } catch (e) {
        debugPrint("FLUX: Error moving track in queue source: $e");
      }
    }

    notifyListeners();
  }

  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= currentQueue.length) return;

    // Remove from local list
    currentQueue.removeAt(index);

    // Remove from just_audio source
    if (_queueSource != null) {
      try {
        await _queueSource!.removeAt(index);
      } catch (e) {
        debugPrint("FLUX: Error removing track from queue source: $e");
      }
    }

    notifyListeners();
  }

  Future<void> addToQueue(Map<String, String> track) async {
    currentQueue.add(Map<String, String>.from(track));

    if (_queueSource != null) {
      try {
        _queueSource!.add(FluxStreamAudioSource(track, this, tag: _createMediaItem(track)));
      } catch (e) {
        debugPrint("FLUX: Error adding track to queue source: $e");
      }
    }

    notifyListeners();
  }

  Future<void> _setAndPlaySource(AudioSource source) async {
    await player.stop();
    await player.setAudioSource(source);
    player.play();
  }

  Future<void> playTrack(
    Map<String, String> track, [
    String? serverStreamUrl,
  ]) async {
    int index = currentQueue.indexWhere((t) =>
        t['track_name'] == track['track_name'] &&
        t['artist'] == track['artist']);
    
    if (index == -1) {
      currentQueue.add(track);
      index = currentQueue.length - 1;
    }
    
    await _playFromQueueIndex(index);
  }

  void playPlaylist(List<Map<String, String>> tracks, {bool shuffle = false}) {
    if (tracks.isEmpty) return;

    _originalQueue = List.from(tracks);
    currentQueue = List.from(tracks);
    _isShuffled = shuffle;
    if (shuffle) currentQueue.shuffle();

    _playFromQueueIndex(0);
  }

  // --- QUEUE CONTROLS ---
  
  PlaybackRepeatMode _repeatMode = PlaybackRepeatMode.off;
  PlaybackRepeatMode get repeatMode => _repeatMode;

  bool _isShuffled = false;
  bool get isShuffled => _isShuffled;
  List<Map<String, String>> _originalQueue = [];

  void toggleRepeatMode() {
    if (_repeatMode == PlaybackRepeatMode.off) {
      _repeatMode = PlaybackRepeatMode.all;
      player.setLoopMode(LoopMode.off); // We handle 'all' manually
    } else if (_repeatMode == PlaybackRepeatMode.all) {
      _repeatMode = PlaybackRepeatMode.one;
      player.setLoopMode(LoopMode.one); // just_audio loops the current source
    } else {
      _repeatMode = PlaybackRepeatMode.off;
      player.setLoopMode(LoopMode.off);
    }
    notifyListeners();
  }

  void toggleShuffle() {
    _isShuffled = !_isShuffled;
    if (_isShuffled) {
      _originalQueue = List.from(currentQueue);
      if (currentTrack != null) {
        currentQueue.removeWhere((t) => t['track_name'] == currentTrack!['track_name'] && t['artist'] == currentTrack!['artist']);
        currentQueue.shuffle();
        currentQueue.insert(0, currentTrack!);
      } else {
        currentQueue.shuffle();
      }
    } else {
      currentQueue = List.from(_originalQueue);
    }
    notifyListeners();
  }


  bool isFavorite(Map<String, String> track) {
    if (!playlists.containsKey("Favoritas")) return false;
    return playlists["Favoritas"]!.any((t) => t['track_name'] == track['track_name'] && t['artist'] == track['artist']);
  }

  void toggleFavorite(Map<String, String> track) {
    if (!playlists.containsKey("Favoritas")) {
      createPlaylist("Favoritas");
    }
    if (isFavorite(track)) {
      removeFromPlaylist("Favoritas", track);
    } else {
      addTrackToPlaylist("Favoritas", track);
    }
    notifyListeners();
  }

  Future<void> skipNext() async {
    if (player.hasNext) {
      await player.seekToNext();
    }
  }

  Future<void> skipPrevious() async {
    if (player.position.inSeconds > 3) {
      player.seek(Duration.zero);
      return;
    }
    if (player.hasPrevious) {
      await player.seekToPrevious();
    } else {
      player.seek(Duration.zero);
    }
  }


  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  MediaItem _createMediaItem(Map<String, String> track) {
    return MediaItem(
      id: track['video_id'] ?? track['track_name'] ?? 'unknown',
      title: track['track_name'] ?? 'Unknown Track',
      artist: track['artist'] ?? 'Unknown Artist',
      artUri: (track['album_image_url'] != null && track['album_image_url']!.isNotEmpty) 
          ? Uri.parse(track['album_image_url']!) 
          : null,
    );
  }
}

class FluxStreamAudioSource extends StreamAudioSource {
  final Map<String, String> track;
  final FluxProvider provider;

  FluxStreamAudioSource(this.track, this.provider, {super.tag});

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (!kIsWeb) {
      final localPath = await provider.getDownloadedAudioPath(track);
      if (await File(localPath).exists()) {
        final file = File(localPath);
        final length = await file.length();
        final effectiveStart = start ?? 0;
        final effectiveEnd = end ?? (length - 1);
        final stream = file.openRead(effectiveStart, effectiveEnd + 1);
        return StreamAudioResponse(
          sourceLength: length,
          contentLength: effectiveEnd - effectiveStart + 1,
          offset: effectiveStart,
          stream: stream,
          contentType: 'audio/mpeg',
        );
      }
    }

    final videoId = await provider._resolveVideoId(track);
    if (videoId == null) throw Exception("Could not resolve video_id");
    final streamUrl =
        "${provider.baseUrl}/stream_audio?id=$videoId&quality=${provider._audioQuality}";

    final request = http.Request('GET', Uri.parse(streamUrl));
    if (start != null || end != null) {
      request.headers['Range'] = 'bytes=${start ?? 0}-${end ?? ''}';
    }
    request.headers['ngrok-skip-browser-warning'] = 'true';

    final response = await http.Client().send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception("Audio server returned HTTP ${response.statusCode}");
    }

    final contentRange = response.headers['content-range'];
    final totalLength = contentRange == null
        ? response.contentLength
        : int.tryParse(contentRange.split('/').last);
    return StreamAudioResponse(
      sourceLength: totalLength,
      contentLength: response.contentLength,
      offset: start ?? 0,
      stream: response.stream,
      contentType: response.headers['content-type'] ?? 'audio/mpeg',
    );
  }
}
