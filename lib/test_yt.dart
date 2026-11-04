import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() async {
  final yt = YoutubeExplode();
  print("Buscando trending via Videos search...");
  try {
    final searchResult = await yt.search.search('2024 Top Hits music audio', filter: TypeFilters.video);
    print("Found \${searchResult.length} videos.");
    if (searchResult.isNotEmpty) {
      print("First: \${searchResult.first.title}");
    }
  } catch (e) {
    print("Erro ao buscar trending: \$e");
  } finally {
    yt.close();
  }
}
