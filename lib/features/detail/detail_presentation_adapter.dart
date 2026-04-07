import '../../data/models/app_media.dart';

class DetailHeaderVm {
  const DetailHeaderVm({
    required this.title,
    required this.subtitle,
    required this.isSeries,
  });

  final String title;
  final String subtitle;
  final bool isSeries;
}

class DetailPresentationAdapter {
  static DetailHeaderVm fromAggregate(AppMediaAggregate aggregate) {
    final type = aggregate.media.type.toUpperCase();
    final isSeries = type == 'SERIES' || type == '#SERIES';
    final subtitle = aggregate.media.releaseYear == null
        ? (isSeries ? 'Series' : 'Movie')
        : '${aggregate.media.releaseYear}';
    return DetailHeaderVm(
      title: aggregate.media.title,
      subtitle: subtitle,
      isSeries: isSeries,
    );
  }
}

