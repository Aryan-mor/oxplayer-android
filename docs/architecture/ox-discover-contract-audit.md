# OX Discover Contract Audit

## Purpose

This document captures the current Discover/Home contract used by the existing oxplayer-android UI.

This is the implementation seam we must satisfy before swapping Discover away from Plex-backed sources.

The source of truth for this audit is the current Flutter UI in `oxplayer-android`, not the legacy app and not a hypothetical backend shape.

## Scope

This audit covers only the current Discover flow:

- Continue Watching / hero feed (`_onDeck`)
- Hub sections (`_hubs`)
- Hero playback entry point
- Card navigation and focus behavior used from Discover
- Android TV Watch Next sync sourced from Discover on-deck items

It does not define the full detail, search, or playback contracts.

## Current Data Loading Contract

Discover currently expects two result sets:

1. `List<PlexMetadata>` for `_onDeck`
2. `List<PlexHub>` for `_hubs`

The screen also depends on these behaviors during loading:

- On-deck and hubs can load independently, with on-deck rendered first.
- Discover must tolerate an empty hub list while hubs are still loading.
- Hidden libraries are applied before content is rendered.
- Hubs are filtered to exclude Continue Watching / On Deck duplicates because `_onDeck` is rendered separately.
- Hubs are sorted by the current library ordering from `LibrariesProvider`.

## `PlexHub` Contract Used By Discover

Discover and `HubSection` consume these `PlexHub` fields directly:

- `hubKey`: stable identity for focus memory
- `title`: rendered section title and icon selection input
- `hubIdentifier`: used to filter out continue-watching style hubs
- `more`: controls whether the header and trailing card navigate to hub detail
- `items`: ordered list of cards rendered inside the section
- `serverId`: used to derive stable library global keys for sorting
- `serverName`: optionally displayed when duplicate titles exist or the setting enables server names
- `librarySectionID`: used for library-order sorting when present

Required behavioral semantics:

- `hubKey` must remain stable across refreshes or focus memory breaks.
- `items` order is presentation order; the UI does not re-rank inside a hub.
- `title` should be human-readable because icon selection is derived from title text.
- `more` should only be true when a hub detail route can be satisfied.

## `PlexMetadata` Contract Used By Discover

### Identity and Routing

These fields are required so cards, hero actions, focus memory, watch-state refresh, and follow-up screens continue working:

- `ratingKey`
- `serverId`
- `serverName`
- `key` for library-section style routing when applicable
- `grandparentRatingKey` for episode-to-show navigation
- `parentRatingKey` for season and episode navigation

Derived behaviors currently depended on by Discover-side widgets:

- `globalKey` must be stable through `buildGlobalKey(serverId, ratingKey)` semantics.
- `isLibrarySection` / `librarySectionKey` behavior must keep working for any whole-library cards.
- `mediaType` must preserve movie/show/season/episode semantics.

### Card Titles and Hierarchy

Discover cards and hero text depend on these fields:

- `title`
- `type`
- `grandparentTitle`
- `parentTitle`
- `parentIndex`
- `index`

Derived title behavior that the compatibility layer must preserve:

- `displayTitle`:
  - episodes and seasons prefer show title
  - seasons can fall back to parent title
  - other items use `title`
- `displaySubtitle`:
  - episodes and seasons can expose item title as subtitle when the display title is the show title

This behavior is not cosmetic only. Existing cards use it to decide:

- main text
- subtitle text
- clickable title routing
- hero label composition

### Artwork and Image Selection

Discover uses multiple image roles, not a single poster field.

Required image-capable fields:

- `thumb`
- `art`
- `grandparentThumb`
- `grandparentArt`
- `parentThumb`
- `clearLogo`
- `backgroundSquare`

Derived image behaviors currently required:

- `posterThumb(...)` must return the correct image source for:
  - poster mode
  - season poster mode
  - episode thumbnail mode
  - mixed hubs containing episodes and non-episodes
- `usesWideAspectRatio(...)` drives whether cards render as 16:9 or 2:3.
- `heroArt(containerAspectRatio: ...)` decides whether hero uses `art` or `backgroundSquare`.

Compatibility implication:

- OX media adapters must provide enough image roles for poster cards, mixed hubs, and hero backgrounds.
- The image contract should be resolved through `MediaRepository`, but the UI still expects Plex-shaped fields at the adapter boundary.

### Progress and Watch State

Discover overlays and hero CTA behavior consume:

- `viewOffset`
- `duration`
- `viewCount`
- `leafCount`
- `viewedLeafCount`
- `lastViewedAt`

Derived semantics currently required:

- `hasActiveProgress` identifies partially watched movies/episodes.
- `isWatched` means:
  - movies/episodes: `viewCount > 0`
  - shows/seasons: `viewedLeafCount >= leafCount`
- season progress bars depend on `viewedLeafCount / leafCount`.
- unwatched badge counts depend on `leafCount - viewedLeafCount`.
- hero CTA switches from `Play` to `minutes left` when progress exists.
- Android TV Watch Next sync uses `lastViewedAt`, `viewOffset`, and `duration`.

Compatibility implication:

- OX browse data must carry real progress semantics, not a boolean watched flag only.

### Summary and Metadata Chips

Discover hero and cards consume:

- `summary`
- `year`
- `contentRating`
- `rating`
- `studio`
- `editionTitle`

These are used for:

- hero metadata row
- hero summary
- card metadata line
- list-view detail text

These fields are lower priority than identity/artwork/progress, but the current UI already renders them when available.

### Spoiler Protection

Discover relies on model-level spoiler semantics through `shouldHideSpoiler` behavior on `PlexMetadata`.

This affects:

- whether episode thumbnails are blurred
- whether summaries are hidden in hero/cards
- whether fallback hero text shows episode code/title instead of summary

Compatibility implication:

- the adapter layer must preserve enough type and hierarchy data for spoiler rules to remain meaningful.

## Discover-Specific Behavioral Contract

### Continue Watching / Hero

`_onDeck` is used for two separate UI responsibilities:

1. Hero carousel source
2. Continue Watching horizontal section source

Current expectations:

- The same item list can feed both hero and continue-watching section.
- Hero item tap starts playback directly.
- Continue Watching card tap:
  - episodes play directly
  - movies can play directly from continue-watching context
- Hero content should preferably contain resumable items because CTA text and progress UI assume that shape.

### Hub Rendering

Current hub rendering expects:

- each hub to contain a stable list of media cards
- mixed hubs to be allowed
- per-hub focus memory keyed by `hubKey`
- optional `View All` handling when `more == true`
- optional server label rendering

### Library Ordering and Filtering

Discover expects a hub to be mappable back to a library key using:

- `hub.librarySectionID`, or
- `hub.items.first.librarySectionID`

If neither exists, the hub still renders, but library-order sorting becomes weaker.

Compatibility implication:

- OX home sections should expose a stable library/collection grouping identifier even if the backend does not think in Plex library terms.

### Multi-Server Assumptions To Remove Later

The current implementation is still Plex-oriented and assumes multi-server semantics in a few places:

- fallback client resolution from `serverId`
- server-name display in duplicate hubs
- library global keys built from `serverId + sectionId`
- Watch Next content ids prefixed with `plezy_{serverId}_{ratingKey}`

For OX migration, we should keep the compatibility surface stable initially, even if backend data is single-origin.

That means Wave 1 can synthesize a stable OX server namespace instead of rewriting Discover immediately.

## Minimum Discover Compatibility Set

If we want the smallest possible Wave 1 seam swap without rewriting the screen, the minimum safe adapter output is:

### For on-deck items

- stable `ratingKey`
- stable `serverId`
- `type`
- `title`
- `grandparentTitle` and `parentTitle` when episodic
- `grandparentRatingKey` and `parentRatingKey` when episodic
- `parentIndex` and `index` when episodic
- `thumb`
- `art` or `backgroundSquare`
- `clearLogo` when available, otherwise Discover falls back to text
- `viewOffset`
- `duration`
- `lastViewedAt`
- `summary`

### For hub items

- all identity/routing fields above
- `librarySectionID`
- enough artwork to support poster or wide-thumb rendering
- enough watch-state fields for overlays
- `year`, `contentRating`, and optional `rating` for richer card metadata

### For hubs

- stable `hubKey`
- `title`
- `items`
- `more`
- `hubIdentifier` or equivalent section type marker
- `librarySectionID`

## Contract Gaps To Solve In OX Design

Before implementing the Discover seam swap, the OX-backed contract must answer these explicitly:

1. What is the stable OX equivalent of `serverId` for compatibility keys?
2. What is the stable OX equivalent of `librarySectionID` for hub ordering?
3. Which image roles can backend/media infrastructure provide for:
   - poster/thumb
   - hero background
   - clear logo
4. How will episodic hierarchy fields be represented so existing title/subtitle/navigation helpers keep working?
5. What watch-progress payload will Discover receive for movies, episodes, shows, and seasons?
6. Which hubs should expose `more == true` in Wave 1?

## Implementation Guidance For The Next Step

The next step should not rewrite Discover.

The next step should define an OX home feed contract that can be deterministically mapped into:

- `List<PlexMetadata>` for continue watching
- `List<PlexHub>` for browse sections

That OX contract should preserve stable identity, hierarchy, progress, and image roles first.

Visual richness fields can remain optional where necessary, but identity and playback/navigation fields cannot.
