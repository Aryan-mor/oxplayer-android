# Implementation Plan: FilePreviewCard

## Overview

Implement `FilePreviewCard` as a unified `StatefulWidget` at `lib/widgets/file_preview_card.dart`, then migrate the two screens that currently use `OxFileOptionCard` or inline file-row patterns. The widget is a direct evolution of `OxFileOptionCard` with the action buttons moved inline into the right column (matching `EpisodeCard`'s layout pattern).

## Tasks

- [ ] 1. Create the FilePreviewCard widget skeleton and public API
  - Create `lib/widgets/file_preview_card.dart` with the `FilePreviewCard` `StatefulWidget` class
  - Declare all constructor parameters per the design API: `title`, `onStream`, `badgeLabel`, `infoLine`, `description`, `imageUrl`, `localPosterPath`, `focusNode`, `autofocus`, `onNavigateUp`, `onNavigateDown`, `downloadGlobalKey`, `onDownload`, `onPause`, `onResume`, `onCancelDownload`, `onDelete`, `onRetry`, `onCast`
  - Declare `_FilePreviewCardState` with `_downloadFocusNode` and `_deleteFocusNode` fields
  - Implement `initState()` to create focus nodes when `downloadGlobalKey != null`
  - Implement `didUpdateWidget()` to dispose and recreate focus nodes when `downloadGlobalKey` changes
  - Implement `dispose()` to dispose both focus nodes
  - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 9.8_

- [ ] 2. Implement card layout and thumbnail
  - [ ] 2.1 Implement the outer card shell
    - Wrap the card in `Padding(vertical: 2)` for outer spacing
    - Wrap the card body in a `FocusableWrapper` (zone 1) with `disableScale: true`, `descendantsAreFocusable: false`, passing through `focusNode`, `autofocus`, `onNavigateUp`, `onNavigateDown`, and `onSelect: onStream`
    - Wrap in `InkWell` with `hoverColor: colorScheme.surface.withValues(alpha: 0.05)` and `onTap: onStream`
    - Wrap in `Container` with `colorScheme.surfaceContainerLow` background, `FocusTheme.defaultBorderRadius` border radius, horizontal padding 8, vertical padding 6
    - Build the inner `Row` with a `SizedBox(width: 160)` thumbnail section and an `Expanded` content section separated by `SizedBox(width: 12)`
    - _Requirements: 1.1, 1.2, 1.9, 1.10, 7.1, 7.2, 7.3, 7.4, 10.1, 10.2, 10.4_

  - [ ] 2.2 Implement `_buildThumbnail()` private helper
    - Priority 1: if `localPosterPath != null` → `Image.file` with `BoxFit.cover`; `errorBuilder` → `PlaceholderContainer` + `AppIcon(Symbols.movie_rounded, size: 32)`
    - Priority 2: if `imageUrl` is non-null and non-empty → `Image.network` with `BoxFit.cover`; `loadingBuilder` → `PlaceholderContainer` + `CircularProgressIndicator(strokeWidth: 2)`; `errorBuilder` → `PlaceholderContainer` + movie icon
    - Priority 3: `PlaceholderContainer` + movie icon
    - Wrap in `ClipRRect(borderRadius: BorderRadius.circular(6))` and `AspectRatio(16/9)` inside the `SizedBox(width: 160)` Stack
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6_

  - [ ] 2.3 Implement the right-side content column
    - Title row: optional badge `Container` (primaryContainer bg, onPrimaryContainer fg, fontSize 11, FontWeight.w600, horizontal padding 6, vertical padding 3, borderRadius 3) followed by `Expanded` title `Text` (titleSmall, FontWeight.bold, maxLines 2, ellipsis)
    - Optional info line: `Text` with bodySmall, `tokens(context).textMuted`, maxLines 2
    - Action buttons row placeholder (wired in task 3)
    - Optional description: `Text` with bodySmall, `tokens(context).textMuted`, height 1.3, maxLines 3
    - _Requirements: 1.4, 1.5, 1.6, 1.7, 1.8_

- [ ] 3. Implement the action buttons row with download state machine
  - [ ] 3.1 Implement the stream and cast buttons
    - Stream button: `IconButton` with `Symbols.play_arrow_rounded` (fill: 1, size: 22), `onPressed: onStream`, `visualDensity: VisualDensity.compact`
    - Cast button: `IconButton` with `Symbols.cast_rounded` (fill: 1, size: 22), `onPressed: null` (always disabled), icon colored `tokens(context).textMuted`, tooltip "Coming soon", `visualDensity: VisualDensity.compact`
    - _Requirements: 3.1, 3.2, 3.3, 6.1, 6.2, 6.3, 10.3_

  - [ ] 3.2 Implement the download button state machine inside `Consumer<DownloadProvider>`
    - Wrap the entire action row in `Consumer<DownloadProvider>` so only the buttons section rebuilds
    - Call `downloadProvider.getProgress(downloadGlobalKey)` and `downloadProvider.isQueueing(downloadGlobalKey)`
    - Implement the full state machine per the design table:
      - `progress == null && !isQueueing` → `AppIcon(download_rounded, primary, size 22)`, callback: `onDownload`
      - `isQueueing` → `PlexStyleDownloadRingIcon(indeterminate: true, diameter: 40, strokeWidth: 2.5, centerIcon: pause icon size 20, progressColor: textMuted)`, callback: `null`
      - `status == queued` → `PlexStyleDownloadRingIcon(indeterminate: true, diameter: 40, strokeWidth: 2.5, centerIcon: pause icon size 20, progressColor: primary)`, callback: `onPause`
      - `status == downloading` → `PlexStyleDownloadRingIcon(indeterminate: false, determinateProgress: progressPercent, diameter: 40, strokeWidth: 2.5, centerIcon: pause icon size 20, progressColor: primary)`, callback: `onPause`
      - `status == paused` → `PlexStyleDownloadRingIcon(indeterminate: false, determinateProgress: progressPercent, diameter: 40, strokeWidth: 2.5, centerIcon: play icon size 20, progressColor: primary)`, callback: `onResume`
      - `status == failed` → `AppIcon(download_rounded, error, size 22)`, callback: `onRetry`
      - `status == cancelled || partial` → `AppIcon(download_rounded, primary, size 22)`, callback: `onDownload`
      - `status == completed` → download button hidden
    - Wrap download button in `FocusableWrapper` (zone 2) with `disableScale: true`, `descendantsAreFocusable: false`, `onNavigateLeft: () => focusNode?.requestFocus()`, `onNavigateDown` to delete focus node when visible
    - Wire zone 1 `onNavigateRight` to `_downloadFocusNode?.requestFocus()` when download button is visible
    - _Requirements: 4.1–4.10, 7.5, 7.7, 7.8, 7.9, 8.1, 8.2, 8.3, 8.4, 10.3, 10.5, 10.6_

  - [ ] 3.3 Implement the delete/cancel button visibility logic
    - `isQueueing || queued || downloading || paused` → `AppIcon(delete_outline_rounded, textMuted, size 20)`, callback: `onCancelDownload`
    - `status == completed` → `AppIcon(delete_outline_rounded, error, size 22)`, callback: `onDelete`
    - All other states (no key, no progress, failed, cancelled) → button hidden
    - Wrap delete/cancel button in `FocusableWrapper` (zone 3) with `disableScale: true`, `descendantsAreFocusable: false`, `onNavigateUp: () => _downloadFocusNode?.requestFocus()`, `onNavigateLeft: () => focusNode?.requestFocus()`
    - Wire zone 2 `onNavigateDown` to `_deleteFocusNode?.requestFocus()` when delete button is visible
    - _Requirements: 5.1–5.6, 7.6, 7.9, 7.10, 7.11, 10.3_

- [ ] 4. Write widget tests for FilePreviewCard
  - Create `test/widgets/file_preview_card_test.dart` with a `MockDownloadProvider` stub
  - [ ]* 4.1 Write property test for layout invariant (Property 1)
    - **Property 1: Layout invariant** — for any valid config, widget tree contains Row → SizedBox(width: 160) + Expanded
    - **Validates: Requirements 1.1, 1.2**

  - [ ]* 4.2 Write property test for title text style invariant (Property 2)
    - **Property 2: Title text style invariant** — for any non-empty title, Text uses titleSmall + FontWeight.bold + maxLines 2 + ellipsis
    - **Validates: Requirements 1.4**

  - [ ]* 4.3 Write property test for optional text fields style (Property 3)
    - **Property 3: Optional text fields rendered with correct style** — description uses bodySmall/textMuted/height 1.3/maxLines 3; infoLine uses bodySmall/textMuted/maxLines 2
    - **Validates: Requirements 1.6, 1.7**

  - [ ]* 4.4 Write property test for badge style (Property 4)
    - **Property 4: Badge rendered with correct style for any label** — badge Container uses primaryContainer bg; badge Text uses onPrimaryContainer fg, fontSize 11, FontWeight.w600
    - **Validates: Requirements 1.8**

  - [ ]* 4.5 Write property test for network image (Property 5)
    - **Property 5: Network image used for any non-empty imageUrl** — when localPosterPath is null and imageUrl is non-empty, thumbnail renders Image.network with BoxFit.cover
    - **Validates: Requirements 2.3**

  - [ ]* 4.6 Write property test for permanent action buttons invariant (Property 6)
    - **Property 6: Permanent action buttons invariant** — for any config, action row always contains stream IconButton (play_arrow_rounded) and cast IconButton (cast_rounded); cast always has onPressed: null
    - **Validates: Requirements 3.1, 6.1, 6.2**

  - [ ]* 4.7 Write property test for progress ring value (Property 7)
    - **Property 7: Progress ring reflects progressPercent for any value** — for any progressPercent in [0.0, 1.0] with status downloading or paused, PlexStyleDownloadRingIcon is in determinate mode with matching determinateProgress
    - **Validates: Requirements 4.6, 4.7**

  - [ ]* 4.8 Write property test for no delete/cancel in idle states (Property 8)
    - **Property 8: No delete/cancel button in idle, failed, or cancelled states** — for configs with no progress + !isQueueing, failed, or cancelled, widget tree contains no delete/cancel IconButton
    - **Validates: Requirements 5.5**

  - [ ]* 4.9 Write property test for VisualDensity.compact (Property 9)
    - **Property 9: VisualDensity.compact on all action row IconButtons** — for any config and download state, every action row IconButton has visualDensity: VisualDensity.compact
    - **Validates: Requirements 10.3**

  - [ ]* 4.10 Write property test for ring dimensions invariant (Property 10)
    - **Property 10: Ring dimensions invariant** — for any active download state rendering a PlexStyleDownloadRingIcon, diameter == 40.0, strokeWidth == 2.5, center AppIcon size == 20.0
    - **Validates: Requirements 10.5, 10.6**

  - [ ]* 4.11 Write example-based tests for thumbnail sources
    - Test: `Image.file` rendered when `localPosterPath` is provided
    - Test: `PlaceholderContainer` rendered when `localPosterPath` file fails to load
    - Test: `PlaceholderContainer` with `CircularProgressIndicator` during network image load
    - Test: `PlaceholderContainer` with movie icon when neither source is provided
    - _Requirements: 2.1, 2.2, 2.4, 2.6_

  - [ ]* 4.12 Write example-based tests for download state machine callbacks
    - Test: tapping download button in idle state invokes `onDownload`
    - Test: tapping download button in queued/downloading state invokes `onPause`
    - Test: tapping download button in paused state invokes `onResume`
    - Test: tapping download button in failed state invokes `onRetry`
    - Test: tapping cancel button in active states invokes `onCancelDownload`
    - Test: tapping delete button in completed state invokes `onDelete`
    - _Requirements: 4.3, 4.5, 4.6, 4.7, 4.8, 5.2, 5.4_

  - [ ]* 4.13 Write example-based tests for focus node lifecycle
    - Test: `didUpdateWidget` recreates focus nodes when `downloadGlobalKey` changes from non-null to null
    - Test: `didUpdateWidget` recreates focus nodes when `downloadGlobalKey` changes from null to non-null
    - _Requirements: 9.7, 9.8_

- [ ] 5. Checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 6. Migrate media_detail_screen.dart — single-file OX video rows
  - In `_buildOxFileOptionsList()`, replace each `OxFileOptionCard(...)` with `FilePreviewCard(...)`
  - Map parameters: `title` → `title`, `badgeLabel` → `badgeLabel`, `infoLine` → `infoLine`, `summary` → `description`, `imageUrl` → `imageUrl`, `downloadGlobalKey` → `downloadGlobalKey`
  - Map callbacks: `onTap` → `onStream`, `onQueueDownload` → `onDownload`, `onPauseDownload` → `onPause`, `onResumeDownload` → `onResume`, `onCancelActiveDownload` → `onCancelDownload`, `onDeleteCompletedDownload` → `onDelete`, `onRetryDownload` → `onRetry`
  - Preserve `focusNode` and `onNavigateUp` pass-through for the first item
  - Add `import '../widgets/file_preview_card.dart'` and remove `import '../widgets/ox_file_option_card.dart'` if no longer used
  - _Requirements: 9.1–9.6_

- [ ] 7. Migrate media_detail_screen.dart — multi-file OX episode rows
  - In `_buildOxMultiFileEpisodeRow()`, replace each `OxFileOptionCard(...)` in the `options.asMap().entries.map(...)` block with `FilePreviewCard(...)`
  - Apply the same parameter and callback mapping as task 6
  - Preserve `focusNode` pass-through for the globally-last item (`isGlobalLast`)
  - Preserve `localPosterPath` pass-through
  - Verify `ox_file_option_card.dart` import can be removed after both usages are replaced
  - _Requirements: 9.1–9.6_

- [ ] 8. Migrate my_telegram_video_detail_screen.dart — Telegram file row
  - Replace the inline download controls section (the `Row` with stream `FilledButton`, forward `IconButton`, and download `IconButton`, plus the `TelegramVideoDownloadControls` block) with a single `FilePreviewCard`
  - Pass `title: v.displayTitle`, `infoLine: fileTechSummary`, `description: v.summary`, `localPosterPath: thumb` (when file exists), `onStream: () => unawaited(_stream())`
  - Wire download callbacks: `onDownload: () => unawaited(_startDownload())`, `onPause: _requestStopDownload`, `onResume: () => unawaited(_resumeDownload())`, `onCancelDownload: _requestStopDownload`, `onDelete: _deleteDownload`
  - Derive a `downloadGlobalKey` from the Telegram item (e.g. `'telegram_${widget.chatId}_${widget.messageId}'`) and pass it; update `_startDownload` / `_runDownload` to use `DownloadProvider` if needed, or keep the existing `TelegramVideoItemUiState` approach and bridge it to the card's callbacks
  - Keep the forward-to-bot `IconButton` outside the card (it is not a file-level action)
  - _Requirements: 9.1–9.6_

- [ ] 9. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests (4.1–4.10) validate universal correctness properties from the design document
- Example-based tests (4.11–4.13) cover specific states and edge cases
- The Telegram migration (task 8) may require bridging `TelegramVideoItemUiState` to `DownloadProvider`; evaluate during implementation and adjust scope as needed
