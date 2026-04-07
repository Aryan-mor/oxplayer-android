import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Last-known browse focus for resuming after detail (shell routes replace Home).
class HomeBrowseFocusState {
  const HomeBrowseFocusState({
    this.lastMainTab = 0,
    this.lastCarouselApiKind,
    this.lastCarouselItemIndex = 0,
    this.lastSourcesGridIndex = 0,
    this.expectResumeAfterDetail = false,
  });

  final int lastMainTab;
  final String? lastCarouselApiKind;
  final int lastCarouselItemIndex;
  final int lastSourcesGridIndex;
  final bool expectResumeAfterDetail;

  HomeBrowseFocusState copyWith({
    int? lastMainTab,
    String? lastCarouselApiKind,
    int? lastCarouselItemIndex,
    int? lastSourcesGridIndex,
    bool? expectResumeAfterDetail,
  }) {
    return HomeBrowseFocusState(
      lastMainTab: lastMainTab ?? this.lastMainTab,
      lastCarouselApiKind: lastCarouselApiKind ?? this.lastCarouselApiKind,
      lastCarouselItemIndex:
          lastCarouselItemIndex ?? this.lastCarouselItemIndex,
      lastSourcesGridIndex: lastSourcesGridIndex ?? this.lastSourcesGridIndex,
      expectResumeAfterDetail:
          expectResumeAfterDetail ?? this.expectResumeAfterDetail,
    );
  }
}

class HomeBrowseFocusNotifier extends StateNotifier<HomeBrowseFocusState> {
  HomeBrowseFocusNotifier() : super(const HomeBrowseFocusState());

  void setCarouselTileFocus({
    required int mainTab,
    required String apiKind,
    required int itemIndex,
  }) {
    state = state.copyWith(
      lastMainTab: mainTab,
      lastCarouselApiKind: apiKind,
      lastCarouselItemIndex: itemIndex,
    );
  }

  void setSourcesGridFocus({
    required int mainTab,
    required int gridIndex,
  }) {
    state = state.copyWith(
      lastMainTab: mainTab,
      lastSourcesGridIndex: gridIndex,
    );
  }

  void markOpeningDetail() {
    state = state.copyWith(expectResumeAfterDetail: true);
  }

  void clearResumeExpectation() {
    state = state.copyWith(expectResumeAfterDetail: false);
  }
}

final homeBrowseFocusProvider =
    StateNotifierProvider<HomeBrowseFocusNotifier, HomeBrowseFocusState>((ref) {
  return HomeBrowseFocusNotifier();
});

