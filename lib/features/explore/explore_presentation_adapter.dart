import '../../data/api/oxplayer_api_service.dart';

class ExploreSectionVm {
  const ExploreSectionVm({
    required this.id,
    required this.title,
    required this.count,
  });

  final String id;
  final String title;
  final int count;
}

class ExplorePresentationAdapter {
  static List<ExploreSectionVm> buildSections({
    required List<ExploreCatalogItem> available,
    required List<ExploreCatalogItem> requested,
    required List<ExploreTmdbItem> tmdb,
  }) {
    return [
      ExploreSectionVm(
        id: 'explore_available',
        title: 'Available',
        count: available.length,
      ),
      ExploreSectionVm(
        id: 'explore_requested',
        title: 'Requested',
        count: requested.length,
      ),
      ExploreSectionVm(id: 'explore_tmdb', title: 'TMDB', count: tmdb.length),
    ];
  }
}
