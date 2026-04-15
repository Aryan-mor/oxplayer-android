# Requirements Document

## Introduction

The `FilePreviewCard` is a unified, reusable Flutter widget that replaces the four separate file-display patterns currently spread across `media_detail_screen.dart` (movie single-page, series episode files, general-video single-page) and `my_telegram_video_detail_screen.dart` (Telegram item file row). The component presents a single playable file variant with a 16:9 thumbnail on the left, a title and description on the right, and a compact row of icon-button actions (stream, download/pause, delete, cast) whose visibility and state react to the current download lifecycle.

## Glossary

- **FilePreviewCard**: The new unified StatefulWidget defined in this spec.
- **DownloadProvider**: The existing `ChangeNotifier` that tracks `DownloadProgress` and `DownloadStatus` for every download key.
- **DownloadStatus**: The existing enum with values `queued`, `downloading`, `paused`, `completed`, `failed`, `cancelled`, `partial`.
- **DownloadProgress**: The existing model that carries `status`, `progressPercent`, and related fields for one download key.
- **PlexStyleDownloadRingIcon**: The existing widget that renders a circular progress ring around a center icon.
- **FocusableWrapper**: The existing widget that adds D-pad/keyboard focus, scale animation, and directional navigation callbacks.
- **AppIcon**: The existing thin wrapper around Material Symbols icons.
- **MonoTokens**: The existing `ThemeExtension` accessed via `tokens(context)`, providing `textMuted` and other design tokens.
- **Download_Global_Key**: A string identifier passed to `DownloadProvider` to look up the progress for a specific file.
- **Stream_Action**: Playing the file via the network without downloading it first.
- **Cast_Action**: Casting the file to an external device (not yet implemented; button is always disabled).
- **Active_Download**: A download whose `DownloadStatus` is `queued`, `downloading`, or `paused`.

---

## Requirements

### Requirement 1: Card Layout

**User Story:** As a user, I want each file variant to be displayed in a consistent card layout so that I can quickly scan thumbnails and titles across all screens.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL render a horizontal `Row` with a fixed-width thumbnail section on the left and a flexible content section occupying the remaining width on the right.
2. THE FilePreviewCard SHALL render the thumbnail at a fixed width of 160 logical pixels with a 16:9 aspect ratio.
3. THE FilePreviewCard SHALL clip the thumbnail with a border radius of 6 logical pixels on all corners.
4. THE FilePreviewCard SHALL display the title text at the top of the right-side content section using `titleSmall` with `fontWeight: FontWeight.bold`, capped at 2 lines with ellipsis overflow.
5. THE FilePreviewCard SHALL display the action buttons row directly below the title.
6. WHERE a description string is provided, THE FilePreviewCard SHALL display it below the action buttons row using `bodySmall` styled with `tokens(context).textMuted` and a line height of 1.3, capped at 3 lines.
7. WHERE an info line string is provided, THE FilePreviewCard SHALL display it between the title and the action buttons row using `bodySmall` styled with `tokens(context).textMuted`, capped at 2 lines.
8. WHERE a badge label string is provided, THE FilePreviewCard SHALL display a pill-shaped badge using `colorScheme.primaryContainer` background and `colorScheme.onPrimaryContainer` foreground at font size 11 with `FontWeight.w600`, positioned to the left of the title text.
9. THE FilePreviewCard SHALL wrap the entire card in a `Container` with `colorScheme.surfaceContainerLow` background and a border radius of `FocusTheme.defaultBorderRadius`, with horizontal padding of 8 and vertical padding of 6.
10. THE FilePreviewCard SHALL apply `EdgeInsets.symmetric(vertical: 2)` outer padding so that stacked cards have consistent spacing.

---

### Requirement 2: Thumbnail Sources

**User Story:** As a developer, I want the card to accept both local file paths and network URLs for thumbnails so that it works in both online and offline modes.

#### Acceptance Criteria

1. WHEN a `localPosterPath` string is provided and the file exists on disk, THE FilePreviewCard SHALL render the thumbnail using `Image.file` with `BoxFit.cover`.
2. WHEN a `localPosterPath` is provided but the file cannot be loaded, THE FilePreviewCard SHALL render a `PlaceholderContainer` with a `Symbols.movie_rounded` `AppIcon` of size 32.
3. WHEN no `localPosterPath` is provided and an `imageUrl` string is provided and is non-empty, THE FilePreviewCard SHALL render the thumbnail using `Image.network` with `BoxFit.cover`.
4. WHEN the network image is loading, THE FilePreviewCard SHALL render a `PlaceholderContainer` with a `CircularProgressIndicator` of `strokeWidth: 2`.
5. WHEN the network image fails to load, THE FilePreviewCard SHALL render a `PlaceholderContainer` with a `Symbols.movie_rounded` `AppIcon` of size 32.
6. WHEN neither `localPosterPath` nor `imageUrl` is provided, THE FilePreviewCard SHALL render a `PlaceholderContainer` with a `Symbols.movie_rounded` `AppIcon` of size 32.

---

### Requirement 3: Stream Action Button

**User Story:** As a user, I want a clearly visible stream (play) button so that I can immediately start watching a file variant.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL always render a stream icon button using `Symbols.play_arrow_rounded` (fill: 1, size: 22).
2. WHEN the `onStream` callback is provided, THE FilePreviewCard SHALL invoke it when the stream button is tapped or selected via D-pad.
3. WHEN the `onStream` callback is null, THE FilePreviewCard SHALL render the stream button in a disabled state.

---

### Requirement 4: Download / Pause Action Button

**User Story:** As a user, I want a single download button that changes to a pause button with a progress ring once a download starts, so that I can manage downloads without navigating away.

#### Acceptance Criteria

1. WHEN no `downloadGlobalKey` is provided, THE FilePreviewCard SHALL NOT render a download/pause button.
2. WHEN a `downloadGlobalKey` is provided and `DownloadProvider` has no progress entry for that key and `isQueueing` is false, THE FilePreviewCard SHALL render a download icon button using `Symbols.download_rounded` (fill: 1, size: 22) colored with `colorScheme.primary`.
3. WHEN the download button is tapped and `onDownload` is provided, THE FilePreviewCard SHALL invoke `onDownload`.
4. WHEN `DownloadProvider.isQueueing` returns true for the key, THE FilePreviewCard SHALL render a `PlexStyleDownloadRingIcon` in indeterminate mode with a `Symbols.pause_rounded` center icon, and the button SHALL be non-interactive (no callback).
5. WHEN `DownloadStatus` is `queued`, THE FilePreviewCard SHALL render a `PlexStyleDownloadRingIcon` in indeterminate mode with a `Symbols.pause_rounded` center icon colored with `colorScheme.primary`, and tapping SHALL invoke `onPause`.
6. WHEN `DownloadStatus` is `downloading`, THE FilePreviewCard SHALL render a `PlexStyleDownloadRingIcon` in determinate mode with `progressPercent` and a `Symbols.pause_rounded` center icon colored with `colorScheme.primary`, and tapping SHALL invoke `onPause`.
7. WHEN `DownloadStatus` is `paused`, THE FilePreviewCard SHALL render a `PlexStyleDownloadRingIcon` in determinate mode with `progressPercent` and a `Symbols.play_arrow_rounded` center icon colored with `colorScheme.primary`, and tapping SHALL invoke `onResume`.
8. WHEN `DownloadStatus` is `failed`, THE FilePreviewCard SHALL render a `Symbols.download_rounded` icon colored with `colorScheme.error`, and tapping SHALL invoke `onRetry`.
9. WHEN `DownloadStatus` is `cancelled` or `partial`, THE FilePreviewCard SHALL render a `Symbols.download_rounded` icon colored with `colorScheme.primary`, and tapping SHALL invoke `onDownload`.
10. WHEN `DownloadStatus` is `completed`, THE FilePreviewCard SHALL NOT render the download/pause button (the delete button takes its place per Requirement 5).

---

### Requirement 5: Delete Action Button

**User Story:** As a user, I want a delete button that only appears when a file is downloaded or actively downloading/paused, so that the UI stays uncluttered for files I haven't downloaded.

#### Acceptance Criteria

1. WHEN `DownloadStatus` is `completed`, THE FilePreviewCard SHALL render a delete icon button using `Symbols.delete_outline_rounded` (fill: 1, size: 22) colored with `colorScheme.error`.
2. WHEN the delete button is tapped and `onDelete` is provided, THE FilePreviewCard SHALL invoke `onDelete`.
3. WHEN `DownloadStatus` is `queued`, `downloading`, or `paused`, THE FilePreviewCard SHALL render a cancel/delete icon button using `Symbols.delete_outline_rounded` (fill: 1, size: 20) colored with `tokens(context).textMuted`.
4. WHEN the cancel button is tapped and `onCancelDownload` is provided, THE FilePreviewCard SHALL invoke `onCancelDownload`.
5. WHEN `DownloadProvider` has no progress entry for the key, `isQueueing` is false, `DownloadStatus` is `failed`, or `DownloadStatus` is `cancelled`, THE FilePreviewCard SHALL NOT render a delete or cancel button.
6. WHEN no `downloadGlobalKey` is provided, THE FilePreviewCard SHALL NOT render a delete or cancel button.

---

### Requirement 6: Cast Action Button

**User Story:** As a user, I want to see a cast button so that I know casting will be available in a future update, even though it is not functional yet.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL always render a cast icon button using `Symbols.cast_rounded` (fill: 1, size: 22).
2. THE FilePreviewCard SHALL render the cast button in a permanently disabled state (null `onPressed`) with its icon colored using `tokens(context).textMuted`.
3. THE FilePreviewCard SHALL set the cast button tooltip to a string indicating the feature is coming soon.

---

### Requirement 7: TV / D-pad Focus Support

**User Story:** As a TV user navigating with a D-pad, I want each interactive element in the card to be individually focusable and navigable so that I can control playback and downloads without a pointer device.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL wrap the main card body (thumbnail + text) in a `FocusableWrapper` with `disableScale: true` and `descendantsAreFocusable: false`.
2. WHEN the card body `FocusableWrapper` receives a select event, THE FilePreviewCard SHALL invoke `onStream`.
3. THE FilePreviewCard SHALL accept an optional external `FocusNode` and `autofocus` flag and pass them to the card body `FocusableWrapper`.
4. THE FilePreviewCard SHALL accept optional `onNavigateUp` and `onNavigateDown` callbacks and pass them to the card body `FocusableWrapper`.
5. WHEN the download/pause button is rendered, THE FilePreviewCard SHALL wrap it in its own `FocusableWrapper` with `disableScale: true` and `descendantsAreFocusable: false`.
6. WHEN the delete/cancel button is rendered, THE FilePreviewCard SHALL wrap it in its own `FocusableWrapper` with `disableScale: true` and `descendantsAreFocusable: false`.
7. WHEN the card body `FocusableWrapper` receives a RIGHT navigation event and a download/pause button is visible, THE FilePreviewCard SHALL move focus to the download/pause button.
8. WHEN the download/pause button `FocusableWrapper` receives a LEFT navigation event, THE FilePreviewCard SHALL move focus back to the card body.
9. WHEN the download/pause button `FocusableWrapper` receives a DOWN navigation event and a delete/cancel button is visible, THE FilePreviewCard SHALL move focus to the delete/cancel button.
10. WHEN the delete/cancel button `FocusableWrapper` receives an UP navigation event, THE FilePreviewCard SHALL move focus back to the download/pause button.
11. WHEN the delete/cancel button `FocusableWrapper` receives a LEFT navigation event, THE FilePreviewCard SHALL move focus back to the card body.

---

### Requirement 8: DownloadProvider Integration

**User Story:** As a developer, I want the card to reactively update its download button state from `DownloadProvider` so that progress and status changes are reflected in real time without manual refresh.

#### Acceptance Criteria

1. WHEN a `downloadGlobalKey` is provided, THE FilePreviewCard SHALL use a `Consumer<DownloadProvider>` to rebuild the action buttons section whenever the provider notifies listeners.
2. THE FilePreviewCard SHALL call `DownloadProvider.getProgress(downloadGlobalKey)` to obtain the current `DownloadProgress`.
3. THE FilePreviewCard SHALL call `DownloadProvider.isQueueing(downloadGlobalKey)` to detect the pre-queue state.
4. THE FilePreviewCard SHALL NOT call `DownloadProvider` methods directly; all download operations SHALL be delegated to the callbacks provided by the parent widget.

---

### Requirement 9: Widget API

**User Story:** As a developer, I want a clean, well-typed widget API so that I can drop `FilePreviewCard` into any of the four existing usage sites with minimal boilerplate.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL be a `StatefulWidget` named `FilePreviewCard` located at `lib/widgets/file_preview_card.dart`.
2. THE FilePreviewCard SHALL accept the following required parameters: `title` (String), `onStream` (VoidCallback?).
3. THE FilePreviewCard SHALL accept the following optional display parameters: `badgeLabel` (String?), `infoLine` (String?), `description` (String?), `imageUrl` (String?), `localPosterPath` (String?).
4. THE FilePreviewCard SHALL accept the following optional focus parameters: `focusNode` (FocusNode?), `autofocus` (bool, default false), `onNavigateUp` (VoidCallback?), `onNavigateDown` (VoidCallback?).
5. THE FilePreviewCard SHALL accept the following optional download parameters: `downloadGlobalKey` (String?), `onDownload` (VoidCallback?), `onPause` (VoidCallback?), `onResume` (VoidCallback?), `onCancelDownload` (VoidCallback?), `onDelete` (VoidCallback?), `onRetry` (VoidCallback?).
6. THE FilePreviewCard SHALL accept the following optional cast parameter: `onCast` (VoidCallback?), which is reserved for future use and SHALL be ignored (cast button remains disabled regardless of its value).
7. THE FilePreviewCard SHALL manage its own internal `FocusNode` instances for the download and delete buttons and dispose them in `dispose()`.
8. WHEN `downloadGlobalKey` changes between widget updates, THE FilePreviewCard SHALL recreate the internal focus nodes in `didUpdateWidget`.

---

### Requirement 10: Visual Consistency with Existing Cards

**User Story:** As a designer, I want `FilePreviewCard` to match the visual style of `OxFileOptionCard` and `EpisodeCard` so that the UI looks cohesive across all screens.

#### Acceptance Criteria

1. THE FilePreviewCard SHALL use `colorScheme.surfaceContainerLow` as the card background color, matching `OxFileOptionCard` and `EpisodeCard`.
2. THE FilePreviewCard SHALL use `FocusTheme.defaultBorderRadius` for the card container border radius, matching `OxFileOptionCard` and `EpisodeCard`.
3. THE FilePreviewCard SHALL use `VisualDensity.compact` on all `IconButton` widgets in the action row, matching `OxFileOptionCard`.
4. THE FilePreviewCard SHALL use `hoverColor: Theme.of(context).colorScheme.surface.withValues(alpha: 0.05)` on the `InkWell`, matching `OxFileOptionCard` and `EpisodeCard`.
5. THE FilePreviewCard SHALL use a `PlexStyleDownloadRingIcon` with `diameter: 40.0` and `strokeWidth: 2.5` for the download progress ring, matching `OxFileOptionCard`.
6. THE FilePreviewCard SHALL use `ringIconSize: 20.0` for the center icon inside `PlexStyleDownloadRingIcon`, matching `OxFileOptionCard`.
