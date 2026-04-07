import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/plezy_models.dart';

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  return MediaRepository();
});

class MediaRepository {
  Future<List<PlexHub>> getHomeData() async {
    return [
      PlexHub(
        title: "Recently Added Movies",
        type: "movie",
        hubIdentifier: "recent",
        size: 2,
        hubKey: "recent",
        more: false,
        items: [
          PlexMetadata(title: "Mock Movie 1", type: "movie", ratingKey: "1"),
          PlexMetadata(title: "Mock Movie 2", type: "movie", ratingKey: "2"),
        ]
      )
    ];
  }

  Future<List<PlexHub>> getMovies() async {
    return [
      PlexHub(
        title: "All Movies",
        type: "movie",
        hubIdentifier: "movies",
        size: 1,
        hubKey: "movies",
        more: false,
        items: [
          PlexMetadata(title: "Mock Movie 1", type: "movie", ratingKey: "1"),
        ]
      )
    ];
  }

  Future<List<PlexHub>> getTvShows() async {
    return [
      PlexHub(
        title: "All TV Shows",
        type: "show",
        hubIdentifier: "tv",
        size: 1,
        hubKey: "tv",
        more: false,
        items: [
          PlexMetadata(title: "Mock Show 1", type: "show", ratingKey: "3"),
        ]
      )
    ];
  }

  Future<PlexMetadata?> getMovieDetails(String id) async {
    return PlexMetadata(title: "Mock Detail", type: "movie", ratingKey: id);
  }
}
