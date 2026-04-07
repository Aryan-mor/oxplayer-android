Plezy Home + Navigation 1:1 Mirror Plan

Goal

Deliver an exact Plezy-style Home experience by cloning widget structure and keyboard/D-pad focus flow from Plezy reference screens, removing hybrid legacy layout/focus behavior from active paths.

Source of Truth





Plezy reference screens:





[c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/refs/plezy/lib/screens/main_screen.dart](c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/refs/plezy/lib/screens/main_screen.dart)



[c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/refs/plezy/lib/screens/discover_screen.dart](c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/refs/plezy/lib/screens/discover_screen.dart)



Current app targets to replace/mirror:





[c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/features/home/home_screen.dart](c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/features/home/home_screen.dart)



[c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/widgets/hub_section.dart](c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/widgets/hub_section.dart)



[c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/widgets/media_card.dart](c:/Users/Aryan/Documents/Projects/oxplayer-wrapper/oxplayer-android/lib/widgets/media_card.dart)

Implementation Steps





Clone Plezy shell/navigation structure into app home root





Mirror Plezy main_screen.dart structure (desktop/TV sidebar layout + content stack + mobile branch if present).



Replace active home_screen.dart widget tree with Plezy-equivalent shell composition (no legacy _SideMenu skeleton retained in active flow).



Preserve route entry (/) but point rendered tree to the mirrored structure.





Clone Plezy Discover tree exactly into Home content





Copy the full CustomScrollView + slivers + overlay stack from Plezy discover_screen.dart into home_screen.dart (or a dedicated mirrored discover widget referenced by home root).



Keep identical section ordering, paddings, and hierarchy.



Do not reshape/condense sections based on current local data shape.





Mirror Plezy focus + D-pad navigation pipeline as-is





Port Plezy focus helpers required by main/discover behavior into app equivalents:





focusable_action_bar, focusable_wrapper, input_mode_tracker, dpad_navigator, key_event_utils, locked_hub_controller, focus_memory_tracker.



Wire FocusScope handoff exactly like Plezy MainScreenFocusScope/content-sidebar transitions.



Ensure vertical Up/Down movement between hub sections follows Plezy rules; ensure left-edge movement returns focus to sidebar exactly as in Plezy.





Mirror dependent Plezy widgets/constants used by the tree





Clone dependency widgets/helpers used by discover/main structure (without hybrid refactors):





side_navigation_rail, hub_section, media_card, focus_builders, horizontal_scroll_with_arrows, navigation_tabs, desktop_window_padding, platform_detector, layout_constants.



Keep structure/props/layout semantics consistent with Plezy; add thin adapter wrappers only where compile-time integration requires namespace/type differences.





Apply placeholder-only data policy for missing fields





Introduce local mock/home placeholder model factories to satisfy all visual fields expected by Plezy cards/hero rows.



Use static placeholders (text/icons/images) for unavailable fields (e.g. director/trending score) so layout remains pixel-consistent.



Keep placeholder mapping isolated from business/domain models.





Deactivate conflicting legacy focus/layout paths





Remove old hybrid focus handoffs and duplicate wrappers from active Home path (e.g. bespoke onKeyEvent branches that conflict with Plezy flow).



Keep legacy files only if unused; ensure active route does not invoke deprecated layout/focus stacks.





Validate clone fidelity and navigation behavior





Run analysis/lints on touched files.



Manual verification checklist:





Sidebar <-> content focus transfer matches Plezy.



Hub-to-hub vertical traversal works across all sections.



Hero/app-bar/hub boundary movements match Plezy behavior.



Visual structure (slivers/sidebar/section blocks) matches Plezy reference without hybrid remnants.

Target Architecture (after migration)

flowchart LR
  appRoot[AppRouter / HomeRoute] --> mainMirror[MainScreenMirror]
  mainMirror --> sideRail[SideNavigationRailMirror]
  mainMirror --> contentStack[IndexedContentStackMirror]
  contentStack --> discoverMirror[DiscoverScreenMirror]
  discoverMirror --> customScroll[CustomScrollViewSlivers]
  customScroll --> heroSection[HeroSection]
  customScroll --> hubSections[HubSectionListMirror]
  mainMirror --> focusScope[MainScreenFocusScope]
  focusScope --> dpadNav[DpadNavigatorMirror]
  focusScope --> focusMemory[FocusMemoryTrackerMirror]
  hubSections --> lockedHub[LockedHubControllerMirror]

Risk Controls





Keep clone in a dedicated mirrored module during migration, then switch route binding once parity is confirmed.



Avoid partial transplant of Plezy internals; copy full dependency chain for any referenced primitive.



If local compile errors arise from missing Plezy-only utilities, copy utility files first before adapting imports.


Hard Directives for the Execution:

Delete, Don't Adapt: Do not try to merge my old SideMenu logic. Delete it from the active path and use the Plezy MainScreen + SideNavigationRail structure 1:1.

Sliver Integrity: You must use the CustomScrollView and Sliver structure from discover_screen.dart. No ListView or Column wrappers that break vertical focus traversal.

Focus Logic Porting: Copy the FocusScope and DpadNavigator logic exactly. If a section is not reachable via Up/Down keys, it's a failure.

Placeholder Injection: If my Riverpod providers are missing data for a Plezy widget, DO NOT change the widget. Create a PlezyMockAdapter that injects placeholder strings/images.
