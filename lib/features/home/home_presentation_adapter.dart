class HomeSectionVm {
  const HomeSectionVm({
    required this.id,
    required this.title,
    required this.kind,
  });

  final String id;
  final String title;
  final String kind;
}

class HomePresentationAdapter {
  static const sections = <HomeSectionVm>[
    HomeSectionVm(id: 'home_movies', title: 'Movies', kind: 'movie'),
    HomeSectionVm(id: 'home_series', title: 'Series', kind: 'series'),
    HomeSectionVm(id: 'home_other', title: 'Other', kind: 'general_video'),
  ];
}
