# Design Document: FilePreviewCard

## Overview

`FilePreviewCard` is a unified, reusable `StatefulWidget` that consolidates four separate file-display patterns currently spread across `media_detail_screen.dart` and `my_telegram_video_detail_screen.dart`. It presents a single playable file variant with a 16:9 thumbnail on the left, a title/badge/info/description column on the right, and a compact row of icon-button actions (stream, download/pause, delete/cancel, cast) whose visibility and state react to the current download lifecycle via `DownloadProvider`.

The widget is a direct evolution of `OxFileOptionCard`. The key design difference is that `FilePreviewCard` places the action buttons **inline in the right column** (below the title), whereas `OxFileOptionCard` places the download column in a separate outer `Row` to the right of the card body. This makes `FilePreviewCard` more compact and consistent with the `EpisodeCard` pattern.

### Key Design Decisions

- **Inline action row**: All four action buttons (stream, download/pause, delete/cancel, cast) live in the right-side `Column`, not in a separate outer column. This avoids the awkward outer-row layout of `OxFileOptionCard` and keeps the card self-contained.
- **Three separate `FocusableWrapper` zones**: Card body, download button, and delete/cancel button each get their own `FocusableWrapper` with explicit D-pad navigation wiring, matching the pattern established in `OxFileOptionCard`.
- **`Consumer<DownloadProvider>` scoped to action row only**: Only the action buttons section rebuilds on provider changes, not the entire card, keeping rebuilds cheap.
- **Internal `FocusNode` lifecycle tied to `downloadGlobalKey`**: Focus nodes are created in `initState` and recreated in `didUpdateWidget` when `downloadGlobalKey` changes, matching `OxFileOptionCard`'s approach.

---

## Architecture

```
FilePreviewCard (StatefulWidget)
│
├── State: _FilePreviewCardState
│   ├── _downloadFocusNode: FocusNode?   (created when downloadGlobalKey != null)
│   ├── _deleteFocusNode: FocusNode?     (created when downloadGlobalKey != null)
│   ├── initState()                      → creates focus nodes
│   ├── didUpdateWidget()                → recreates focus nodes if key changes
│   └── dispose()                        → disposes focus nodes
│
└── build()
    └── Padding(vertical: 2)             [outer spacing]
        └── FocusableWrapper             [zone 1: card body]
            └── InkWell
                └── Container           [surfaceContainerLow, FocusTheme.defaultBorderRadius, h:8 v:6]
                    └── Row
                        ├── SizedBox(width: 160)   [thumbnail section]
                        │   └── Stack
                        │       └── ClipRRect(radius: 6)
                        │           └── AspectRatio(16/9)
                        │               └── _buildThumbnail()
                        │
                        └── SizedBox(width: 12)
                        └── Expanded                [content section]
                            └── Column
                                ├── Row             [title row]
                                │   ├── badge (optional)
                                │   └── Expanded → Text(title)
                                │
                                ├── [infoLine Text] (optional)
                                │
                                ├── Consumer<DownloadProvider>   [action buttons row]
                                │   └── Row
                                │       ├── FocusableWrapper     [zone 1 select → onStream]
                                │       │   └── IconButton(stream)
                                │       ├── FocusableWrapper     [zone 2: download button]
                                │       │   └── IconButton(download/pause/ring)
                                │       ├── FocusableWrapper     [zone 3: delete/cancel button]
                                │       │   └── IconButton(delete/cancel)
                                │       └── IconButton(cast, always disabled)
                                │
                                └── [description Text] (optional)
```

> **Note on focus zones**: The stream button is inside the card body `FocusableWrapper` (zone 1) and is activated via `onSelect`. The download and delete buttons each have their own `FocusableWrapper` (zones 2 and 3) with explicit D-pad wiring. The cast button has no `FocusableWrapper` since it is always disabled.

---

## Components and Interfaces

### `FilePreviewCard` — Public API

```dart
class FilePreviewCard extends StatefulWidget {
  const FilePreviewCard({
    super.key,
    // Required
    required this.title,
    required this.onStream,
    // Optional display
    this.badgeLabel,
    this.infoLine,
    this.description,
    this.imageUrl,
    this.localPosterPath,
    // Optional focus
    this.focusNode,
    this.autofocus = false,
    this.onNavigateUp,
    this.onNavigateDown,
    // Optional download
    this.downloadGlobalKey,
    this.onDownload,
    this.onPause,
    this.onResume,
    this.onCancelDownload,
    this.onDelete,
    this.onRetry,
    // Optional cast (reserved, always disabled)
    this.onCast,
  });

  final String title;
  final VoidCallback? onStream;

  final String? badgeLabel;
  final String? infoLine;
  final String? description;
  final String? imageUrl;
  final String? localPosterPath;

  final FocusNode? focusNode;
  final bool autofocus;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onNavigateDown;

  final String? downloadGlobalKey;
  final VoidCallback? onDownload;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancelDownload;
  final VoidCallback? onDelete;
  final VoidCallback? onRetry;

  final VoidCallback? onCast; // reserved; cast button is always disabled
}
```

### `_FilePreviewCardState` — Internal State

| Field | Type | Purpose |
|---|---|---|
| `_downloadFocusNode` | `FocusNode?` | Focus zone for the download/pause button |
| `_deleteFocusNode` | `FocusNode?` | Focus zone for the delete/cancel button |

Both nodes are created in `initState` when `downloadGlobalKey != null`, recreated in `didUpdateWidget` when `downloadGlobalKey` changes, and disposed in `dispose()`.

### `_buildThumbnail()` — Private Helper

Returns the appropriate thumbnail widget based on the priority chain:

1. `localPosterPath` is non-null → `Image.file` with `BoxFit.cover`; `errorBuilder` → `PlaceholderContainer` + movie icon
2. `imageUrl` is non-null and non-empty → `Image.network` with `BoxFit.cover`; `loadingBuilder` → `PlaceholderContainer` + `CircularProgressIndicator(strokeWidth: 2)`; `errorBuilder` → `PlaceholderContainer` + movie icon
3. Neither → `PlaceholderContainer` + movie icon

### `_buildActionButtons()` — Private Helper (inside `Consumer<DownloadProvider>`)

Returns the `Row` of action buttons. Called inside a `Consumer<DownloadProvider>` builder so it rebuilds reactively.

**Download button state machine** (only rendered when `downloadGlobalKey != null`):

| Condition | Widget | Callback |
|---|---|---|
| `progress == null && !isQueueing` | `AppIcon(download_rounded, primary)` | `onDownload` |
| `isQueueing` | `PlexStyleDownloadRingIcon(indeterminate, pause icon)` | `null` (disabled) |
| `status == queued` | `PlexStyleDownloadRingIcon(indeterminate, pause icon, primary)` | `onPause` |
| `status == downloading` | `PlexStyleDownloadRingIcon(determinate(progressPercent), pause icon, primary)` | `onPause` |
| `status == paused` | `PlexStyleDownloadRingIcon(determinate(progressPercent), play icon, primary)` | `onResume` |
| `status == failed` | `AppIcon(download_rounded, error)` | `onRetry` |
| `status == cancelled \| partial` | `AppIcon(download_rounded, primary)` | `onDownload` |
| `status == completed` | *(hidden)* | — |

**Delete/cancel button visibility**:

| Condition | Widget | Callback |
|---|---|---|
| `isQueueing \| queued \| downloading \| paused` | `AppIcon(delete_outline_rounded, textMuted, size 20)` | `onCancelDownload` |
| `status == completed` | `AppIcon(delete_outline_rounded, error, size 22)` | `onDelete` |
| everything else | *(hidden)* | — |

**Cast button**: Always rendered, always `onPressed: null`, icon colored `tokens(context).textMuted`.

### Dependencies

| Dependency | Usage |
|---|---|
| `OxFileOptionCard` | Visual reference; card shell, padding, colors, ring dimensions |
| `EpisodeCard` | Visual reference; inline action row pattern |
| `PlexStyleDownloadRingIcon` | Download progress ring (`diameter: 40.0`, `strokeWidth: 2.5`) |
| `FocusableWrapper` | Three focus zones with D-pad navigation |
| `AppIcon` | All icons in the action row |
| `DownloadProvider` | `getProgress(key)`, `isQueueing(key)` via `Consumer` |
| `PlaceholderContainer` | Thumbnail fallback states |
| `tokens(context).textMuted` | Muted icon/text color |
| `FocusTheme.defaultBorderRadius` | Card container border radius |

---

## Data Models

No new data models are introduced. The widget consumes existing models:

### `DownloadProgress` (existing)

```dart
class DownloadProgress {
  final String globalKey;
  final DownloadStatus status;
  final int progress;          // 0–100
  // ...
  double get progressPercent => progress / 100.0;
}
```

### `DownloadStatus` (existing enum)

```
queued | downloading | paused | completed | failed | cancelled | partial
```

### Widget Input Summary

All data flows in through constructor parameters. The widget is purely reactive — it reads from `DownloadProvider` and delegates all mutations to parent-provided callbacks.

```
Parent widget
  ├── title, badgeLabel, infoLine, description   → display
  ├── imageUrl, localPosterPath                  → thumbnail
  ├── focusNode, autofocus, onNavigateUp/Down    → focus
  ├── downloadGlobalKey                          → DownloadProvider lookup key
  └── onStream, onDownload, onPause, onResume,
      onCancelDownload, onDelete, onRetry, onCast → action callbacks
```

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Property 1: Layout invariant

*For any* valid `FilePreviewCard` configuration (any combination of title, optional fields, and download state), the rendered widget tree SHALL contain a `Row` whose first child is a `SizedBox` with `width: 160` and whose second child is an `Expanded` widget.

**Validates: Requirements 1.1, 1.2**

---

### Property 2: Title text style invariant

*For any* non-empty title string, the rendered `Text` widget for the title SHALL use `titleSmall` text style with `fontWeight: FontWeight.bold`, `maxLines: 2`, and `overflow: TextOverflow.ellipsis`.

**Validates: Requirements 1.4**

---

### Property 3: Optional text fields rendered with correct style

*For any* non-empty `description` string, the rendered `Text` widget SHALL use `bodySmall` style with `tokens(context).textMuted` color, `height: 1.3`, and `maxLines: 3`. *For any* non-empty `infoLine` string, the rendered `Text` widget SHALL use `bodySmall` style with `tokens(context).textMuted` color and `maxLines: 2`.

**Validates: Requirements 1.6, 1.7**

---

### Property 4: Badge rendered with correct style for any label

*For any* non-empty `badgeLabel` string, the rendered badge `Container` SHALL use `colorScheme.primaryContainer` background, and the badge `Text` SHALL use `colorScheme.onPrimaryContainer` foreground, `fontSize: 11`, and `FontWeight.w600`.

**Validates: Requirements 1.8**

---

### Property 5: Network image used for any non-empty imageUrl

*For any* non-empty `imageUrl` string when `localPosterPath` is null, the thumbnail section SHALL render an `Image.network` widget with `BoxFit.cover`.

**Validates: Requirements 2.3**

---

### Property 6: Permanent action buttons invariant

*For any* `FilePreviewCard` configuration, the action row SHALL always contain a stream `IconButton` with `Symbols.play_arrow_rounded` (fill: 1, size: 22) and a cast `IconButton` with `Symbols.cast_rounded` (fill: 1, size: 22). The cast button SHALL always have `onPressed: null` and its icon SHALL be colored with `tokens(context).textMuted`.

**Validates: Requirements 3.1, 6.1, 6.2**

---

### Property 7: Progress ring reflects progressPercent for any value

*For any* `progressPercent` value in `[0.0, 1.0]`, when `DownloadStatus` is `downloading` or `paused`, the `PlexStyleDownloadRingIcon` SHALL be rendered in determinate mode with `determinateProgress` equal to that `progressPercent` value.

**Validates: Requirements 4.6, 4.7**

---

### Property 8: No delete/cancel button in idle, failed, or cancelled states

*For any* `FilePreviewCard` where `downloadGlobalKey` is provided and the download state is one of `{no progress + !isQueueing, failed, cancelled}`, the widget tree SHALL NOT contain a delete or cancel `IconButton`.

**Validates: Requirements 5.5**

---

### Property 9: VisualDensity.compact on all action row IconButtons

*For any* `FilePreviewCard` configuration and download state, every `IconButton` rendered in the action row SHALL have `visualDensity: VisualDensity.compact`.

**Validates: Requirements 10.3**

---

### Property 10: Ring dimensions invariant

*For any* download state that renders a `PlexStyleDownloadRingIcon`, the widget SHALL be constructed with `diameter: 40.0`, `strokeWidth: 2.5`, and the center `AppIcon` SHALL have `size: 20.0`.

**Validates: Requirements 10.5, 10.6**

---

## Error Handling

### Thumbnail Loading Failures

Both `Image.file` and `Image.network` use their respective `errorBuilder` callbacks to fall back to `PlaceholderContainer` with a `Symbols.movie_rounded` `AppIcon` of size 32. This is consistent with `OxFileOptionCard` and `EpisodeCard`.

### Missing Callbacks

All action callbacks are nullable. When a callback is `null`, the corresponding `IconButton` is rendered with `onPressed: null` (disabled state). The widget never throws on a missing callback.

### DownloadProvider Unavailable

The `Consumer<DownloadProvider>` widget requires `DownloadProvider` to be in the widget tree. If it is absent, Flutter will throw a `ProviderNotFoundException` at runtime. This is consistent with all other widgets in the codebase that use `Consumer<DownloadProvider>` and is the caller's responsibility to satisfy.

### Focus Node Lifecycle

If `downloadGlobalKey` is set to `null` after being non-null (or vice versa), `didUpdateWidget` disposes the old focus nodes and creates new ones (or disposes and sets to `null`). This prevents stale focus nodes from holding references.

---

## Testing Strategy

### Dual Testing Approach

Both unit/widget tests and property-based tests are used. Widget tests cover specific states, callback invocations, and structural checks. Property-based tests verify universal invariants across generated inputs.

### Property-Based Testing Library

Use [`dart_test` + `fast_check`](https://pub.dev/packages/fast_check) (or the equivalent `glados` package for Dart) for property-based testing. Each property test runs a minimum of **100 iterations**.

Each property test is tagged with a comment in the format:
```
// Feature: file-preview-card, Property N: <property text>
```

### Property Tests

| Property | Test Description |
|---|---|
| P1: Layout invariant | Generate random title + optional fields; verify Row → SizedBox(160) + Expanded structure |
| P2: Title style | Generate random title strings; verify Text style, maxLines, overflow |
| P3: Optional text style | Generate random description/infoLine strings; verify bodySmall/textMuted/height/maxLines |
| P4: Badge style | Generate random badgeLabel strings; verify Container/Text styling |
| P5: Network image | Generate random non-empty imageUrl strings; verify Image.network with BoxFit.cover |
| P6: Permanent buttons | Generate random configs; verify stream + cast buttons always present, cast always disabled |
| P7: Progress ring value | Generate random progressPercent in [0,1]; verify ring determinateProgress matches |
| P8: No delete in idle states | Generate configs for idle/failed/cancelled; verify no delete/cancel button |
| P9: VisualDensity.compact | Generate random configs; verify all action row IconButtons have compact density |
| P10: Ring dimensions | Generate active download states; verify diameter=40, strokeWidth=2.5, center icon size=20 |

### Widget (Example-Based) Tests

Unit tests cover the remaining acceptance criteria not addressed by property tests:

- **Thumbnail sources**: `Image.file` for local path, `PlaceholderContainer` on error, loading state for network image
- **Download state machine**: Each `DownloadStatus` value renders the correct icon and invokes the correct callback
- **Delete/cancel visibility**: Each active status shows cancel; completed shows delete
- **Focus wiring**: D-pad navigation between the three focus zones
- **API contract**: All constructor parameters are accepted and passed through correctly
- **Focus node lifecycle**: `didUpdateWidget` recreates nodes when `downloadGlobalKey` changes

### Test File Location

```
test/widgets/file_preview_card_test.dart
```

### Integration with Existing Screens

After the widget is implemented, the four existing usage sites should be migrated one at a time:

1. `media_detail_screen.dart` — movie single-page file row
2. `media_detail_screen.dart` — series episode file rows
3. `media_detail_screen.dart` — general-video single-page file row
4. `my_telegram_video_detail_screen.dart` — Telegram item file row

Each migration should be verified by running the existing screen-level tests and manual smoke testing on both phone and TV form factors.
