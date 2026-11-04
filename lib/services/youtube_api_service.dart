import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class YouTubeApiService {
  Future<String> _getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    // Use localhost fallback for development
    return prefs.getString('flux_server_url') ?? 'http://127.0.0.1:9000';
  }

  Future<List<Map<String, String>>> fetchTrending() async {
    try {
      final baseUrl = await _getBaseUrl();
      final response = await http.get(Uri.parse('$baseUrl/trending'));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map<Map<String, String>>((video) => <String, String>{
          "track_name": video["title"]?.toString() ?? "Desconhecido",
          "artist": video["channel"]?.toString() ?? "Desconhecido",
          "album_image_url": "https://i.ytimg.com/vi/${video['video_id']}/hqdefault.jpg",
          "video_id": video["video_id"]?.toString() ?? "",
        }).toList();
      } else {
        print("Erro no backend ao buscar trending: ${response.statusCode}");
      }
    } catch (e) {
      print("Erro ao buscar trending: $e");
    }
    return [];
  }

  Future<List<Map<String, String>>> fetchByGenre(String genre) async {
    try {
      final baseUrl = await _getBaseUrl();
      final query = Uri.encodeComponent("$genre hits 2024");
      final response = await http.get(Uri.parse('$baseUrl/trending?q=$query'));

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map<Map<String, String>>((video) => <String, String>{
          "track_name": video["title"]?.toString() ?? "Desconhecido",
          "artist": video["channel"]?.toString() ?? "Desconhecido",
          "album_image_url": "https://i.ytimg.com/vi/${video['video_id']}/hqdefault.jpg",
          "video_id": video["video_id"]?.toString() ?? "",
        }).toList();
      } else {
        print("Erro no backend ao buscar gênero: ${response.statusCode}");
      }
    } catch (e) {
      print("Erro ao buscar gênero $genre: $e");
    }
    return [];
  }

  void dispose() {
    // No longer needed
  }
}
