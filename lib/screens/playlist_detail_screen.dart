import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/flux_provider.dart';
import '../widgets/mini_player_bar.dart';
import '../main.dart';
import 'artist_screen.dart';

// dart:io só existe no mobile/desktop, nunca no web
import 'dart:io' if (dart.library.html) 'dart_io_stub.dart';

class PlaylistDetailScreen extends StatefulWidget {
  final String playlistName;
  final List<Map<String, String>> tracks;
  final bool readOnly;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistName,
    required this.tracks,
    this.readOnly = false,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late List<Map<String, String>> filteredTracks;
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    filteredTracks = List.from(widget.tracks);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _filterTracks(String query) {
    setState(() {
      if (query.isEmpty) {
        filteredTracks = List.from(widget.tracks);
      } else {
        filteredTracks = widget.tracks.where((track) {
          final trackName = (track['track_name'] ?? '').toLowerCase();
          final artist = (track['artist'] ?? '').toLowerCase();
          final searchLower = query.toLowerCase();
          return trackName.contains(searchLower) || artist.contains(searchLower);
        }).toList();
      }
    });
  }

  void _showChangeCoverDialog(BuildContext context, FluxProvider provider) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Alterar Capa'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: 'URL da imagem...',
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Pick from phone storage
              if (!kIsWeb)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open_outlined, size: 18),
                    label: const Text('Escolher do celular'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: FluxApp.accentColor,
                      side: BorderSide(color: FluxApp.accentColor.withValues(alpha: 0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () async {
                      Navigator.pop(dialogContext);
                      await _pickCoverFromStorage(context, provider);
                    },
                  ),
                ),
              if (!kIsWeb) const SizedBox(height: 8),
              // Pick from existing track covers
              if (widget.tracks.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.photo_library_outlined, size: 18),
                    label: const Text('Escolher de uma música'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: FluxApp.accentColor,
                      side: BorderSide(color: FluxApp.accentColor.withValues(alpha: 0.4)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _showPickCoverFromTracks(context, provider);
                    },
                  ),
                ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          Row(
            children: [
              TextButton(
                onPressed: () {
                  provider.removePlaylistCover(widget.playlistName);
                  Navigator.pop(dialogContext);
                },
                child: const Text('Padrão', style: TextStyle(color: FluxApp.secondaryTextColor)),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancelar'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  if (controller.text.isNotEmpty) {
                    provider.setPlaylistCover(widget.playlistName, controller.text.trim());
                  }
                  Navigator.pop(dialogContext);
                },
                child: const Text('Salvar', style: TextStyle(color: FluxApp.accentColor)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickCoverFromStorage(BuildContext context, FluxProvider provider) async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        // Copy the image to app's documents directory for persistence
        final appDir = await getApplicationDocumentsDirectory();
        final coverDir = Directory('${appDir.path}/playlist_covers');
        if (!await coverDir.exists()) {
          await coverDir.create(recursive: true);
        }
        final fileName = '${widget.playlistName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}_cover${_getExtension(image.path)}';
        final savedFile = await File(image.path).copy('${coverDir.path}/$fileName');
        provider.setPlaylistCover(widget.playlistName, savedFile.path);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao selecionar imagem: $e'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  String _getExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot != -1) return path.substring(dot);
    return '.jpg';
  }

  void _showPickCoverFromTracks(BuildContext context, FluxProvider provider) {
    // Get unique album images from tracks
    final uniqueImages = <String>{};
    for (final track in widget.tracks) {
      final url = track['album_image_url'];
      if (url != null && url.isNotEmpty) uniqueImages.add(url);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Escolher capa', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: uniqueImages.length,
                itemBuilder: (_, i) {
                  final url = uniqueImages.elementAt(i);
                  return GestureDetector(
                    onTap: () {
                      provider.setPlaylistCover(widget.playlistName, url);
                      Navigator.pop(ctx);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(right: 10),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(url, width: 100, height: 100, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 100, height: 100, color: FluxApp.cardColor,
                            child: const Icon(Icons.broken_image, color: FluxApp.secondaryTextColor),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _showTrackOptions(
    BuildContext context,
    Map<String, String> track,
    FluxProvider provider,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48, height: 48,
                    child: (track['album_image_url'] ?? '').isNotEmpty
                        ? Image.network(track['album_image_url']!, fit: BoxFit.cover,
                            errorBuilder: (c, e, s) => const Icon(Icons.music_note, size: 48))
                        : const Icon(Icons.music_note, size: 48),
                  ),
                ),
                title: Text(track['track_name'] ?? 'Música', style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(track['artist'] ?? ''),
              ),
              const Divider(indent: 16, endIndent: 16),
              // Go to artist page
              ListTile(
                leading: const Icon(Icons.person_outline, color: FluxApp.accentColor),
                title: const Text('Ver artista'),
                onTap: () {
                  Navigator.pop(context);
                  final artist = track['artist'];
                  if (artist != null && artist.isNotEmpty) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ArtistScreen(artistName: artist)),
                    );
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add, color: FluxApp.accentColor),
                title: const Text('Adicionar a outra playlist'),
                onTap: () {
                  Navigator.pop(context);
                  _showAddToPlaylistDialog(context, track, provider);
                },
              ),
              if (!kIsWeb)
                FutureBuilder<bool>(
                  future: provider.isTrackDownloaded(track),
                  builder: (context, snapshot) {
                    final isDownloaded = snapshot.data ?? false;
                    if (isDownloaded) {
                      return ListTile(
                        leading: const Icon(Icons.offline_pin_rounded, color: FluxApp.accentColor),
                        title: const Text('Remover Download'),
                        onTap: () {
                          Navigator.pop(context);
                          provider.deleteDownloadedTrack(track);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: const Text("Download removido!"),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          );
                        },
                      );
                    } else {
                      return ListTile(
                        leading: const Icon(Icons.download_rounded, color: FluxApp.accentColor),
                        title: const Text('Baixar música'),
                        onTap: () async {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text("Baixando ${track['track_name']}..."),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          );
                          bool success = await provider.downloadTrack(track);
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(success ? "Download concluído!" : "Erro ao baixar."),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          }
                        },
                      );
                    }
                  },
                ),
              if (!widget.readOnly)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  title: const Text('Remover desta playlist', style: TextStyle(color: Colors.redAccent)),
                  onTap: () {
                    provider.removeFromPlaylist(widget.playlistName, track);
                    setState(() {
                      filteredTracks.remove(track);
                      widget.tracks.remove(track);
                    });
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text("Música removida"),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _showAddToPlaylistDialog(
    BuildContext context,
    Map<String, String> track,
    FluxProvider provider,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Adicionar a..."),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: provider.playlists.keys.map((name) {
              return ListTile(
                leading: const Icon(Icons.playlist_add, color: FluxApp.accentColor),
                title: Text(name),
                onTap: () {
                  provider.addTrackToPlaylist(name, track);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Adicionada a $name"),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  );
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _onTrackTap(
    BuildContext context,
    Map<String, String> track,
    FluxProvider provider,
  ) async {
    if (!kIsWeb) {
      final localPath = await provider.getDownloadedAudioPath(track);
      try {
        if (await File(localPath).exists()) {
          debugPrint("FLUX: Local file found! Playing: $localPath");
          provider.currentQueue = List.from(filteredTracks);
          provider.playTrack(track);
          return;
        }
      } catch (_) {}
    }



    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Carregando ${track['track_name']}..."),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }

    provider.currentQueue = List.from(filteredTracks);
    provider.playTrack(track);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Pesquisar música ou artista...',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: Colors.white54),
                ),
                style: const TextStyle(color: Colors.white, fontSize: 18),
                onChanged: _filterTracks,
              )
            : Text(widget.playlistName, style: const TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _filterTracks('');
                }
              });
            },
          ),
          if (!_isSearching && !widget.readOnly)
            PopupMenuButton<String>(
              color: const Color(0xFF1E1E2E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              onSelected: (value) async {
                final provider = Provider.of<FluxProvider>(context, listen: false);
                if (value == 'cover') {
                  _showChangeCoverDialog(context, provider);
                } else if (value == 'download') {
                  if (kIsWeb) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text("Download de playlist não disponível no navegador."),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Baixando '${widget.playlistName}' em segundo plano..."),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  );
                  final success = await provider.downloadEntirePlaylist(
                    widget.playlistName,
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          success
                              ? "Download da playlist concluído!"
                              : "Algumas músicas falharam. Toque em baixar novamente para tentar de novo.",
                        ),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  }
                } else if (value == 'delete') {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF1E1E2E),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      title: const Text("Apagar Playlist?"),
                      content: Text("Tem certeza que deseja apagar '${widget.playlistName}'?"),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("Cancelar", style: TextStyle(color: Colors.white)),
                        ),
                        TextButton(
                          onPressed: () {
                            provider.deletePlaylist(widget.playlistName);
                            Navigator.pop(context);
                            Navigator.pop(context);
                          },
                          child: const Text("Apagar", style: TextStyle(color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  );
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'cover',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.image_outlined, color: FluxApp.accentColor),
                    title: Text('Alterar Capa'),
                  ),
                ),
                if (!kIsWeb)
                  const PopupMenuItem(
                    value: 'download',
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.download_for_offline_rounded, color: FluxApp.accentColor),
                      title: Text('Baixar Playlist'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline, color: Colors.redAccent),
                    title: Text('Apagar Playlist', style: TextStyle(color: Colors.redAccent)),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: widget.tracks.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_off_rounded, size: 64, color: FluxApp.secondaryTextColor.withValues(alpha: 0.4)),
                  const SizedBox(height: 16),
                  const Text("Nenhuma música nesta playlist", style: TextStyle(color: FluxApp.secondaryTextColor)),
                ],
              ),
            )
          : Column(
              children: [
                // --- HERO HEADER ---
                Consumer<FluxProvider>(
                  builder: (context, provider, _) {
                    final coverUrl = provider.getPlaylistCover(widget.playlistName);
                    final isShuffled = provider.isPlaylistShuffled(widget.playlistName);
                    final trackCount = widget.tracks.length;

                    return Container(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                      child: Column(
                        children: [
                          // Cover + info
                          Row(
                            children: [
                              // Cover image
                              GestureDetector(
                                onTap: () => _showChangeCoverDialog(context, provider),
                                child: Stack(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: 120, height: 120,
                                        child: coverUrl != null && coverUrl.isNotEmpty
                                            ? _buildCoverImage(coverUrl)
                                            : _coverPlaceholder(),
                                      ),
                                    ),
                                    Positioned(
                                      bottom: 4, right: 4,
                                      child: Container(
                                        padding: const EdgeInsets.all(4),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.6),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.camera_alt_outlined, size: 16, color: Colors.white70),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 16),
                              // Playlist info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      widget.playlistName,
                                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white),
                                      maxLines: 2, overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '$trackCount música${trackCount != 1 ? 's' : ''}',
                                      style: const TextStyle(fontSize: 14, color: FluxApp.secondaryTextColor),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          // Play / Shuffle buttons
                          Row(
                            children: [
                              Expanded(
                                child: _PlayModeButton(
                                  icon: Icons.play_arrow_rounded,
                                  label: "Tocar",
                                  isActive: !isShuffled,
                                  onPressed: () {
                                    provider.setPlaylistShuffle(widget.playlistName, false);
                                    provider.playPlaylist(filteredTracks, shuffle: false);
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _PlayModeButton(
                                  icon: Icons.shuffle_rounded,
                                  label: "Aleatório",
                                  isActive: isShuffled,
                                  onPressed: () {
                                    provider.setPlaylistShuffle(widget.playlistName, true);
                                    provider.playPlaylist(filteredTracks, shuffle: true);
                                  },
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
                ),
                Expanded(
                  child: filteredTracks.isEmpty
                      ? const Center(child: Text("Nenhuma música encontrada."))
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: filteredTracks.length,
                          itemBuilder: (context, index) {
                            final track = filteredTracks[index];
                            return Consumer<FluxProvider>(
                              builder: (context, provider, child) {
                                final status = provider.getTrackStatus(track);
                                final isCurrentlyPlaying = provider.currentTrack != null &&
                                    provider.currentTrack!['track_name'] == track['track_name'] &&
                                    provider.currentTrack!['artist'] == track['artist'];

                                return FutureBuilder<bool>(
                                  future: provider.isTrackDownloaded(track),
                                  builder: (context, snapshot) {
                                    final downloadedOnDisk = snapshot.data ??
                                        status == "DOWNLOADED";
                                    return Container(
                                      color: isCurrentlyPlaying
                                          ? FluxApp.accentColor.withValues(alpha: 0.08)
                                          : Colors.transparent,
                                      child: ListTile(
                                    leading: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(6),
                                          child: SizedBox(
                                            width: 48, height: 48,
                                            child: (track['album_image_url'] ?? '').isNotEmpty
                                                ? Image.network(
                                                    track['album_image_url']!,
                                                    fit: BoxFit.cover,
                                                    errorBuilder: (_, __, ___) => Container(
                                                      color: FluxApp.cardColor,
                                                      child: const Icon(Icons.music_note, size: 24, color: FluxApp.accentColor),
                                                    ),
                                                  )
                                                : Container(
                                                    color: FluxApp.cardColor,
                                                    child: const Icon(Icons.music_note, size: 24, color: FluxApp.accentColor),
                                                  ),
                                          ),
                                        ),
                                        if (status == "DOWNLOADING" && provider.getProgress(track) != null)
                                          Container(
                                            width: 48, height: 48,
                                            decoration: BoxDecoration(
                                              color: Colors.black45,
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: ValueListenableBuilder<double>(
                                              valueListenable: provider.getProgress(track)!,
                                              builder: (context, value, _) => CircularProgressIndicator(
                                                value: value,
                                                color: FluxApp.accentColor,
                                                strokeWidth: 3,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                    title: Text(
                                      track['track_name'] ?? '',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isCurrentlyPlaying ? FluxApp.accentColor : FluxApp.primaryTextColor,
                                      ),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      status == "QUEUED"
                                          ? "Na fila..."
                                          : status == "DOWNLOADING"
                                              ? "Baixando..."
                                              : status == "FAILED"
                                                  ? "Falha no download"
                                                  : track['artist'] ?? '',
                                      style: TextStyle(
                                        color: status == "QUEUED"
                                            ? FluxApp.accentColor.withValues(alpha: 0.7)
                                            : FluxApp.secondaryTextColor,
                                        fontSize: 13,
                                      ),
                                      maxLines: 1, overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (downloadedOnDisk)
                                          const Icon(Icons.check_circle_rounded, color: FluxApp.accentColor, size: 18),
                                        if (!downloadedOnDisk && status == "FAILED")
                                          const Icon(Icons.error_rounded, color: Colors.redAccent, size: 18),
                                        IconButton(
                                          icon: Icon(
                                            provider.isFavorite(track) ? Icons.favorite : Icons.favorite_border,
                                            size: 20,
                                            color: provider.isFavorite(track) ? FluxApp.accentColor : FluxApp.secondaryTextColor,
                                          ),
                                          onPressed: () => provider.toggleFavorite(track),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.more_vert, size: 20),
                                          onPressed: () => _showTrackOptions(context, track, provider),
                                        ),
                                      ],
                                    ),
                                    onTap: () => _onTrackTap(context, track, provider),
                                      ),
                                    );
                                  },
                                );
                              },
                            );
                          },
                        ),
                ),
                const SafeArea(top: false, child: MiniPlayerBar()),
              ],
            ),
    );
  }

  Widget _buildCoverImage(String url) {
    // Check if it's a local file path
    if (url.startsWith('/') || url.startsWith('C:') || url.startsWith('D:') || !url.startsWith('http')) {
      return Image.file(
        File(url),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _coverPlaceholder(),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _coverPlaceholder(),
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [FluxApp.cardColor, FluxApp.accentColor.withValues(alpha: 0.2)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.music_note_rounded, size: 48, color: FluxApp.secondaryTextColor),
      ),
    );
  }
}

class _PlayModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onPressed;

  const _PlayModeButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: isActive ? FluxApp.accentColor : FluxApp.cardColor,
            borderRadius: BorderRadius.circular(24),
            border: isActive ? null : Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20, color: isActive ? Colors.white : FluxApp.secondaryTextColor),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 14,
                  color: isActive ? Colors.white : FluxApp.secondaryTextColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
