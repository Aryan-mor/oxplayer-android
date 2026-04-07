import '../data/models/app_media.dart';
import '../widgets/hub_section.dart';

class PlezyLayoutAdapters {
  const PlezyLayoutAdapters._();

  static HubSectionData toHubSection({
    required String hubKey,
    required String title,
    required List<AppMediaAggregate> items,
  }) {
    return HubSectionData(
      hubKey: hubKey,
      title: title,
      items: items,
    );
  }
}

