# OX Browse Migration Plan

## Goal

Migrate the existing browse-focused app experience away from Plex-backed data sources while preserving the current oxplayer-android UI/UX, especially:

- Home/discover shell and navigation
- Existing cards, sections, and detail layouts
- Android TV and D-pad behavior
- Responsive mobile/tablet/TV behavior

The target product scope for this migration is intentionally limited to:

- Movie and series browse lists shown as cards
- Movie and series detail pages
- Search for movies and series
- Playback bootstrap and media resolution

Anything outside this scope should be disabled, hidden, or deferred instead of migrated by default.

## Core Decision

Do not build a new Home UI.

Reuse the current Home/discover experience and existing navigation shell. Replace data seams under the UI by introducing OX-backed compatibility adapters that provide the minimum Plex-shaped contract the existing screens already expect.

This is not a plan to rebuild Plex end-to-end.

It is a scoped compatibility strategy so the existing production UI can keep working while the data source moves from Plex to OX backend plus Telegram/media infrastructure.

## Non-Goals

The following areas are out of scope for the first migration wave and should be hidden or left untouched unless they become necessary later:

- Live TV
- DVR
- Full multi-server Plex parity
- Full Plex profile behavior parity
- Watch Together parity
- Companion remote parity
- Complete Plex API compatibility

## Migration Principles

1. Preserve working UX first, replace data second.
2. Prefer adapting data contracts over rewriting existing layouts.
3. Keep all transport, auth, Telegram, and media access behind infrastructure boundaries.
4. Do not introduce new page-level UI if the existing screen can be reused.
5. If a screen depends on Plex-shaped models, satisfy that dependency through scoped adapters, not view-level hacks.
6. Remove unsupported surfaces before expanding the compatibility layer.
7. Keep the compatibility surface intentionally small and feature-scoped.

## Architectural Direction

The app should move toward three collaborating infrastructure areas:

- `data_repository/`: authenticated app data, browse feeds, details, search, watch state, and high-level domain queries
- `media_repository/`: image resolution, local image cache policy, stream resolution, subtitle access, and playback bootstrap
- `plex_compat/`: adapters that transform OX data into the minimum Plex-shaped models required by the existing UI

The UI should remain dependent on stable view models or compatibility models, not raw API responses or Telegram-specific contracts.

## Required Repository Structure

Do not allow `DataRepository`, `MediaRepository`, or `plex_compat` to become godfiles.

They should be split into folders with multiple focused files.

Suggested structure:

```text
lib/infrastructure/
  data_repository/
    data_repository.dart
    auth/
      auth_session_service.dart
      telegram_auth_service.dart
      bootstrap_service.dart
    browse/
      browse_feed_service.dart
      browse_library_service.dart
    details/
      media_detail_service.dart
      series_children_service.dart
    search/
      search_service.dart
    watch_state/
      watch_state_service.dart

  media_repository/
    media_repository.dart
    images/
      image_cache_policy.dart
      image_file_store.dart
      image_resolver.dart
      image_cache_housekeeping.dart
    playback/
      playback_source_service.dart
      stream_resolver.dart
      subtitle_resolver.dart
      playback_bootstrap_service.dart

  plex_compat/
    plex_compat.dart
    browse/
      plex_hub_adapter.dart
      plex_library_adapter.dart
      plex_metadata_card_adapter.dart
    details/
      plex_detail_adapter.dart
      plex_series_adapter.dart
      plex_episode_adapter.dart
    search/
      plex_search_adapter.dart
    keys/
      plex_compat_keys.dart
```

Notes:

- `data_repository.dart`, `media_repository.dart`, and `plex_compat.dart` should be thin facades, not implementation dumps.
- Each facade should compose smaller services.
- Screen-specific hacks should not live inside repositories.

## Existing UI Contract We Must Preserve

The existing browse UI is not only requesting JSON data. It expects specific model semantics and behavior.

At minimum, the compatibility layer must preserve:

- Stable ids for navigation and focus
- Stable global keys
- Type semantics for movie, show, season, episode
- Poster, thumbnail, art, logo, and avatar image references
- Progress and continue-watching semantics
- Detail-page drill-down for series -> seasons -> episodes
- Search results shaped like existing media cards
- Playback entry points from cards and detail pages

The key constraint is that the UI consumes Plex-shaped models, not just generic app data.

Therefore the migration should transform OX domain data into a limited Plex-compatible contract instead of rewriting the screens.

## Product Scope for Wave 1

Wave 1 should include only the following user journeys:

1. Open the app and land in the existing Home/discover experience.
2. Browse card sections for movies and series.
3. Open movie or show detail pages.
4. For shows, navigate seasons and episodes.
5. Search movies and series.
6. Start playback from browse, detail, or search.

Everything else should be treated as optional and disabled when unsupported.

## Proposed Migration Phases

### Phase 0: Scope Lock and UI Reuse

Actions:

- Keep the current Home/discover shell.
- Keep the current cards, sections, focus behavior, and responsive layout.
- Hide or disable out-of-scope tabs and product areas such as Live TV and DVR.
- Preserve the current main navigation structure as much as possible.

Outcome:

- The migration is constrained to data seams, not page redesign.

### Phase 1: Contract Audit for Existing Screens

Audit only the screens in scope:

- Discover/Home
- Media detail
- Search
- Playback bootstrap entry points

For each screen, document the exact fields and behavior it consumes from:

- `PlexMetadata`
- `PlexHub`
- `PlexLibrary`
- playback bootstrap data

Outcome:

- A minimum compatibility contract for Wave 1
- No attempt to support unused Plex features

### Phase 2: Backend Contract Completion

Use current OX backend as the source of truth and add only the endpoints needed to satisfy the Wave 1 contract.

Current backend already covers part of the library contract with list and detail endpoints.

Likely required additions for Wave 1:

- Home/discover feed endpoint
- Search endpoint
- Series children endpoint for seasons and episodes
- Playback bootstrap endpoint

Outcome:

- The app receives OX-shaped data purpose-built for browse/detail/search/playback

### Phase 3: Build OX Infrastructure Services

Implement focused services under `data_repository/` and `media_repository/`.

`data_repository/` responsibilities:

- auth session bootstrap
- browse feed fetching
- library list fetching
- search
- detail fetching
- series children fetching
- watch state queries and updates

`media_repository/` responsibilities:

- resolve image sources to cacheable local files
- resolve playable media sources
- resolve subtitles and alternate streams
- prepare playback bootstrap data

Outcome:

- No screen talks directly to raw API or Telegram/media backends

### Phase 4: Build Plex Compatibility Adapters

Implement a thin compatibility layer that converts OX domain responses to the minimum existing UI models.

Adapters should cover:

- Home hubs -> `PlexHub`
- browse items -> `PlexMetadata`
- series and episode trees -> `PlexMetadata`
- search results -> `List<PlexMetadata>`
- optional browse groups -> `PlexLibrary`

Outcome:

- The current UI can be reused with minimal or zero layout changes

### Phase 5: Replace Discover/Home Data Seam

Replace the current Home/discover data source first.

Rules:

- Keep the existing screen and layout
- Keep the section and card components
- Remove or hide any unsupported sections instead of redesigning the page
- Feed the screen through the new OX + compatibility path

Outcome:

- Existing Home UI renders OX-backed browse content

### Phase 6: Replace Search

Search is a narrower seam than Home and should be migrated right after Discover.

Rules:

- Preserve current search UI and focus handling
- Return search results already shaped for existing card widgets

Outcome:

- Search works over OX data without Plex server dependency

### Phase 7: Replace Detail Pages

Migrate movie/show/season detail flows using the same compatibility approach.

Required detail capabilities:

- full metadata
- show seasons
- season episodes
- continue-watching or next episode information
- extras if available, otherwise an empty compatible result

Outcome:

- Existing detail screens open from OX-backed browse and search results

### Phase 8: Replace Playback Bootstrap

Playback may remain the least Plex-compatible area.

If necessary, keep the UI entry points but route playback through `MediaRepository` and a custom player or custom playback bootstrap.

Rules:

- Do not force playback to mimic Plex if the media source model is fundamentally different
- Do preserve the user-visible navigation and launch points

Outcome:

- Browse/detail/search remain reusable even if playback becomes OX-native under the hood

## MediaRepository Cache Strategy

`MediaRepository` should prefer local file paths for images whenever practical.

That means image resolution should not stop at returning a remote URL. It should resolve, cache, and return a local file path when the image is suitable for local reuse.

### Cache Policy by Image Type

Different image categories should not all behave the same.

#### Episode thumbnails and lightweight thumbs

These should be treated as cheap, reusable local artifacts.

Preferred behavior:

- fetch once when needed
- store locally
- return file path
- keep longer if storage allows
- optimize for fast repeated rendering in lists and details

Reason:

- thumbs are lightweight
- they are heavily reused in TV-focused browsing
- local file paths reduce repeated network and decoding overhead

#### Posters

Posters should also usually be cached locally and exposed as file paths, especially for list cards and detail headers.

Preferred behavior:

- cache locally
- return file path where possible
- allow periodic cleanup with a moderate retention policy

#### Backdrops, banners, and large hero art

These should use a more aggressive eviction policy.

Preferred behavior:

- cache when needed
- allow scheduled cleanup
- shorter retention window than thumbs/posters
- prioritize disk safety over long-term persistence

Reason:

- these assets are larger
- they create more storage pressure
- they are often less critical to preserve permanently

#### Logos and avatars

These should have separate policy buckets because their sizes and usage frequency differ from posters and art.

### Media Cache Design Rules

1. `MediaRepository` should own image type policy.
2. The UI should not decide eviction or cache persistence rules.
3. Local file return paths should be the preferred output for reusable images.
4. The cache strategy should distinguish thumbnails from large artwork.
5. Cleanup should be safe, scheduled, and category-aware.

## Reuse Existing Project Storage Infrastructure

Do not invent a brand-new storage subsystem if the project already has working primitives for storage and cleanup.

The migration should reuse and extend existing project infrastructure where possible, especially:

- image cache infrastructure
- local artwork storage logic
- settings-driven storage cleanup
- existing directory and file management services

This includes reusing concepts already present in the project for:

- local artwork directories
- hashed file naming
- cache clearing and maintenance hooks
- storage path management

Expected direction:

- keep using the current project storage patterns as the base
- adapt them for OX media and Telegram-backed assets
- avoid parallel cache systems unless there is a clear hard requirement

## Compatibility Boundary Rules

1. Screens and widgets must not fetch OX API data directly.
2. Screens and widgets must not perform Telegram media resolution directly.
3. `DataRepository` and `MediaRepository` must remain infrastructure boundaries.
4. Compatibility adapters must be pure transformation layers as much as possible.
5. Cache keys, synthetic ids, and global keys must be deterministic.

## Deterministic Key Strategy

Because the existing UI depends heavily on stable ids, the compatibility layer must define deterministic rules for:

- synthetic rating keys
- synthetic server ids or source ids
- global keys
- parent-child references across shows, seasons, and episodes

These keys must remain stable across app restarts and refreshes, otherwise focus restore, watch-state updates, navigation, and list refresh behavior will become unreliable.

## Main Risks

### Risk 1: Compatibility surface grows uncontrollably

Mitigation:

- limit migration to browse/detail/search/playback
- audit only fields used by screens in scope
- do not chase complete Plex parity

### Risk 2: Repositories become godfiles

Mitigation:

- enforce multi-file folder structure
- split by domain and responsibility
- keep facade files thin

### Risk 3: Playback assumptions leak into UI migration

Mitigation:

- isolate playback bootstrap behind `MediaRepository`
- preserve UI entry points but allow playback internals to diverge from Plex

### Risk 4: Image caching becomes inconsistent

Mitigation:

- centralize image policy in `MediaRepository`
- classify image types explicitly
- reuse existing storage and cache-management primitives

### Risk 5: Unsupported features slow the core migration

Mitigation:

- hide or disable unsupported surfaces early
- do not migrate out-of-scope tabs first

## Acceptance Criteria for Wave 1

Wave 1 is successful when:

1. The existing Home/discover UI renders OX-backed browse content.
2. Existing card layouts and focus behavior remain intact on Android TV.
3. Search works over OX-backed content.
4. Movie and series detail screens open and render usable content.
5. Season and episode drill-down works for series.
6. Playback can start from browse, detail, and search.
7. No screen in scope talks directly to raw API or Telegram/media endpoints.
8. The new infrastructure is split across focused files and folders, not godfiles.
9. Images are cached with type-aware policy, returning local file paths where appropriate.

## Immediate Next Implementation Step

The next implementation step should be:

1. Audit the exact Home/discover contract currently used by the app
2. Define the minimum OX Home feed contract
3. Implement `plex_compat` mappings for Home only
4. Replace the Discover data seam before touching Search or Detail

This keeps the first migration narrow, testable, and aligned with the current UX.
