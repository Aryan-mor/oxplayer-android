# Implementation Plan: Relay TV Cast

## Overview

This implementation plan breaks down the Relay TV Cast feature into discrete, sequential coding tasks. The feature enables users to cast media from mobile/tablet devices to TV using a relay-based architecture with a Go backend, Flutter/Dart sender and receiver implementations, and Kotlin Android foreground service.

The implementation follows this sequence:
1. Backend API implementation (Go)
2. Shared data models (Dart)
3. Sender implementation (Flutter/Dart)
4. Receiver implementation (Flutter/Dart)
5. Android foreground service (Kotlin)
6. FCM integration (Dart + Kotlin)
7. Settings and UI integration
8. Integration and wiring

## Tasks

- [x] 1. Set up backend API structure and data models
  - Create `server/cast/` directory for cast-related handlers
  - Define Go structs for CastJob, CreateCastJobRequest, ClaimJobResponse
  - Define in-memory storage structure (map[userId]CastJob with mutex)
  - Set up job expiration mechanism (5-minute TTL)
  - _Requirements: 1.2, 11.5_

- [x] 1.1 Write property test for job expiration
  - **Property 15: Job Expiration**
  - **Validates: Requirements 11.5**

- [x] 2. Implement POST /me/cast/jobs endpoint
  - [x] 2.1 Create handler function for cast job creation
    - Parse and validate request payload (chatId, messageId, fileId, fileName, mimeType, totalBytes, thumbnailUrl, metadata)
    - Generate unique job ID (UUID)
    - Store job in memory keyed by userId
    - Return HTTP 201 with job ID and createdAt timestamp
    - _Requirements: 1.1, 1.2, 1.3_

  - [x] 2.2 Write property test for cast job creation request structure
    - **Property 1: Cast Job Creation Request Structure**
    - **Validates: Requirements 1.1**

  - [x] 2.3 Write property test for successful job creation response
    - **Property 29: Successful Job Creation Response**
    - **Validates: Requirements 1.3**

  - [x] 2.4 Write unit tests for POST /me/cast/jobs
    - Test valid payload returns 201
    - Test invalid payload returns 400
    - Test missing auth token returns 401
    - Test server error returns 500
    - _Requirements: 1.4_

  - [x] 2.5 Add error handling for invalid payloads and server errors
    - Return HTTP 400 for invalid payload
    - Return HTTP 500 for server errors
    - _Requirements: 1.4_

  - [x] 2.6 Write property test for backend error response codes
    - **Property 28: Backend Error Response Codes**
    - **Validates: Requirements 1.4**

- [x] 3. Implement GET /me/cast/jobs/claim endpoint with long polling
  - [x] 3.1 Create handler function for job claiming
    - Parse timeout query parameter (default 30s, max 60s)
    - Check if job exists for userId
    - If job exists, return immediately with HTTP 200 and job payload
    - If no job exists, hold request open for timeout duration
    - If job created during hold, return immediately with HTTP 200
    - If timeout expires, return HTTP 204
    - Implement atomic claim operation (remove job from memory on first claim)
    - _Requirements: 2.1, 3.1, 4.1, 4.2_

  - [x] 3.2 Write property test for atomic job claiming
    - **Property 4: Atomic Job Claiming**
    - **Validates: Requirements 4.1, 4.2, 4.3, 4.4, 12.2**

  - [x] 3.3 Write property test for broadcast delivery to all receivers
    - **Property 3: Broadcast Delivery to All Receivers**
    - **Validates: Requirements 3.1, 3.4, 3.5, 12.1**

  - [x] 3.4 Write property test for concurrent connection support
    - **Property 16: Concurrent Connection Support**
    - **Validates: Requirements 12.3**

  - [x] 3.5 Write property test for post-claim notification
    - **Property 17: Post-Claim Notification**
    - **Validates: Requirements 12.4**

  - [x] 3.6 Write unit tests for GET /me/cast/jobs/claim
    - Test immediate return when job exists
    - Test long polling timeout returns 204
    - Test concurrent claims (first succeeds, second returns 404)
    - Test missing auth token returns 401
    - _Requirements: 2.1, 3.1, 4.3_

- [x] 4. Implement POST /me/cast/jobs/:id/started endpoint
  - [x] 4.1 Create handler function for job acknowledgment
    - Parse job ID from URL path
    - Remove job from memory (if exists)
    - Return HTTP 200 with acknowledgment response
    - Implement idempotent behavior (return 200 even if job doesn't exist)
    - _Requirements: 7.2, 7.3_

  - [x] 4.2 Write property test for acknowledgment idempotency
    - **Property 7: Acknowledgment Idempotency**
    - **Validates: Requirements 7.2, 7.3**

  - [x] 4.3 Write unit tests for POST /me/cast/jobs/:id/started
    - Test acknowledgment for existing job returns 200
    - Test acknowledgment for non-existent job returns 200
    - Test missing auth token returns 401
    - _Requirements: 7.2, 7.3_

- [x] 5. Implement POST /me/devices/register endpoint
  - [x] 5.1 Create handler function for FCM token registration
    - Parse request payload (deviceId, fcmToken, platform, appVersion)
    - Store FCM token in database associated with userId and deviceId
    - Return HTTP 200 with registration confirmation
    - _Requirements: 10.2, 10.4_

  - [x] 5.2 Write property test for FCM token registration
    - **Property 12: FCM Token Registration**
    - **Validates: Requirements 10.2, 10.3**

  - [x] 5.3 Write unit tests for POST /me/devices/register
    - Test valid payload returns 200
    - Test invalid payload returns 400
    - Test missing auth token returns 401
    - _Requirements: 10.2_

- [x] 6. Integrate FCM Admin SDK in backend
  - [x] 6.1 Add FCM Admin SDK dependency to Go project
    - Add firebase-admin-go to go.mod
    - Initialize FCM client with service account credentials
    - _Requirements: 3.2_

  - [x] 6.2 Implement FCM push notification sending
    - When cast job is created, query database for all FCM tokens for userId
    - Send FCM push notification to all registered devices
    - Include job metadata in notification payload (type: "cast_job")
    - Log errors but don't fail the request if FCM fails
    - _Requirements: 3.2_

  - [x] 6.3 Write unit tests for FCM integration
    - Test FCM push sent when job created
    - Test FCM error doesn't fail job creation
    - _Requirements: 3.2_

- [x] 7. Checkpoint - Ensure backend tests pass
  - Ensure all backend tests pass, ask the user if questions arise.

- [x] 8. Create shared Dart data models
  - [x] 8.1 Create CastJob model class
    - Define CastJob class with all fields (jobId, chatId, messageId, fileId, fileName, mimeType, totalBytes, thumbnailUrl, metadata, createdAt)
    - Implement fromJson and toJson methods
    - Add to lib/models/cast_job.dart
    - _Requirements: 1.1_

  - [x] 8.2 Create CastException class
    - Define CastException with message and originalError fields
    - Add to lib/exceptions/cast_exception.dart
    - _Requirements: 11.1_

  - [x] 8.3 Create HydratedFile model class
    - Define HydratedFile class with fileId, fileName, mimeType, totalBytes, peerConnection, metadata
    - Add to lib/models/hydrated_file.dart
    - _Requirements: 5.2_

  - [x] 8.4 Write unit tests for data models
    - Test CastJob fromJson/toJson round trip
    - Test HydratedFile construction
    - Test CastException message formatting

- [x] 9. Implement CastService for sender
  - [x] 9.1 Create CastService class
    - Initialize with Dio client and base URL
    - Implement createCastJob method (POST /me/cast/jobs)
    - Implement isCasting method (check active cast jobs map)
    - Implement clearCastJob method (remove from active jobs map)
    - Track active cast jobs in memory (fileId -> jobId map)
    - Add to lib/services/cast_service.dart
    - _Requirements: 1.1, 9.3_

  - [x] 9.2 Write property test for cast button state for active jobs
    - **Property 10: Cast Button State for Active Jobs**
    - **Validates: Requirements 9.3**

  - [x] 9.3 Write unit tests for CastService
    - Test createCastJob with valid payload
    - Test createCastJob with network error
    - Test isCasting returns correct state
    - Test clearCastJob removes job
    - _Requirements: 1.1, 9.3_

  - [x] 9.4 Add error handling for cast job creation
    - Handle network errors (display "Cast service unavailable")
    - Handle auth errors (display "Authentication required")
    - Handle server errors (display "Cast failed, please try again")
    - _Requirements: 11.1_

  - [x] 9.5 Write property test for backend unavailable error display
    - **Property 30: Backend Unavailable Error Display**
    - **Validates: Requirements 11.1**

- [x] 10. Implement CastReceiverService for receiver
  - [x] 10.1 Create CastReceiverService class extending ChangeNotifier
    - Initialize with Dio client, base URL, and SettingsService
    - Implement startPolling method (starts foreground service and polling loop)
    - Implement stopPolling method (stops foreground service and cancels polling)
    - Implement setCastEnabled method (persists toggle state and starts/stops polling)
    - Implement _poll method (long polling with 30s timeout)
    - Implement exponential backoff on network errors (1s, 2s, 4s, ..., max 60s)
    - Add to lib/services/cast_receiver_service.dart
    - _Requirements: 2.1, 2.2, 2.3, 8.3, 8.4_

  - [x] 10.2 Write property test for exponential backoff on network errors
    - **Property 2: Exponential Backoff on Network Errors**
    - **Validates: Requirements 2.3, 11.2**

  - [x] 10.3 Write property test for polling loop continuity
    - **Property 19: Polling Loop Continuity**
    - **Validates: Requirements 2.2**

  - [x] 10.4 Write property test for toggle enable starts polling
    - **Property 20: Toggle Enable Starts Polling**
    - **Validates: Requirements 8.3**

  - [x] 10.5 Write property test for toggle disable stops polling
    - **Property 21: Toggle Disable Stops Polling**
    - **Validates: Requirements 2.6, 8.4**

  - [x] 10.6 Write property test for immediate re-polling on 204
    - **Property 18: Immediate Re-polling on 204**
    - **Validates: Requirements 12.5**

  - [x] 10.2 Implement _handleCastJob method
    - Show "Cast in progress..." notification
    - Call _hydratePeer to resolve fileId to peer connection
    - Call _stopCurrentPlayback to stop current media
    - Call _openPlayer with hydrated metadata
    - Call _acknowledgeJobStarted (fire-and-forget with retries)
    - Show success notification "Now playing: {fileName}"
    - Handle errors and show error notification
    - _Requirements: 5.1, 6.1, 6.2, 7.1_

  - [x] 10.7 Write property test for peer hydration completeness
    - **Property 5: Peer Hydration Completeness**
    - **Validates: Requirements 5.1, 5.2, 5.4**

  - [x] 10.8 Write property test for playback preemption
    - **Property 6: Playback Preemption**
    - **Validates: Requirements 6.1, 6.2, 6.3**

  - [x] 10.9 Write property test for playback start triggers acknowledgment
    - **Property 27: Playback Start Triggers Acknowledgment**
    - **Validates: Requirements 7.1**

  - [x] 10.10 Write property test for hydration progress notification
    - **Property 25: Hydration Progress Notification**
    - **Validates: Requirements 5.5**

  - [x] 10.11 Write property test for preemption notification
    - **Property 26: Preemption Notification**
    - **Validates: Requirements 6.4**

  - [x] 10.3 Implement _hydratePeer method
    - Call TelegramService.instance.hydrateFile with chatId, messageId, fileId
    - Retry up to 3 times on network errors with 1s, 2s, 3s delays
    - Return HydratedFile on success
    - Throw exception after 3 failed attempts
    - _Requirements: 5.1, 11.3_

  - [x] 10.12 Write property test for hydration retry on network errors
    - **Property 13: Hydration Retry on Network Errors**
    - **Validates: Requirements 11.3**

  - [x] 10.13 Write property test for hydration failure prevents playback
    - **Property 23: Hydration Failure Prevents Playback**
    - **Validates: Requirements 5.3**

  - [x] 10.4 Implement _acknowledgeJobStarted method
    - Fire-and-forget POST request to /me/cast/jobs/:id/started
    - Retry up to 3 times with exponential backoff (2s, 4s, 6s)
    - Don't block playback waiting for acknowledgment
    - _Requirements: 7.4, 7.5_

  - [x] 10.14 Write property test for acknowledgment retry pattern
    - **Property 8: Acknowledgment Retry Pattern**
    - **Validates: Requirements 7.4, 7.5**

  - [x] 10.15 Write property test for job ID storage after claim
    - **Property 24: Job ID Storage After Claim**
    - **Validates: Requirements 4.5**

  - [x] 10.5 Implement handleFCMPush method
    - Immediately call GET /me/cast/jobs/claim (bypasses long polling)
    - Handle job if claim succeeds
    - Log error if claim fails
    - _Requirements: 3.3_

  - [x] 10.16 Write property test for FCM notification triggers claim
    - **Property 22: FCM Notification Triggers Claim**
    - **Validates: Requirements 3.3**

  - [x] 10.6 Add error handling for auth errors
    - Stop polling on HTTP 401
    - Display "Cast receiver: Authentication error" notification
    - Disable cast toggle
    - _Requirements: 2.4_

  - [x] 10.7 Add network resilience
    - Auto-resume polling when connectivity is restored
    - Continue retrying with exponential backoff during network errors
    - _Requirements: 11.4_

  - [x] 10.17 Write property test for network resilience
    - **Property 14: Network Resilience**
    - **Validates: Requirements 11.4**

  - [x] 10.18 Write unit tests for CastReceiverService
    - Test startPolling starts foreground service
    - Test stopPolling stops foreground service
    - Test exponential backoff on network errors
    - Test auth error stops polling
    - Test handleFCMPush claims job immediately
    - Test _hydratePeer retries on network errors
    - Test _acknowledgeJobStarted retries on failure
    - _Requirements: 2.1, 2.3, 2.4, 3.3, 7.4, 11.3_

- [x] 11. Checkpoint - Ensure Dart service tests pass
  - Ensure all Dart service tests pass, ask the user if questions arise.

- [x] 12. Implement Android foreground service (Kotlin)
  - [x] 12.1 Create CastForegroundService class
    - Extend Android Service class
    - Implement onCreate, onStartCommand, onBind methods
    - Create notification channel "Cast Receiver"
    - Create persistent notification "Ready to Cast"
    - Return START_STICKY from onStartCommand
    - Add companion object with start() and stop() methods
    - Add to android/app/src/main/kotlin/com/plezy/oxplayer/CastForegroundService.kt
    - _Requirements: 2.5_

  - [x] 12.2 Add CastForegroundService to AndroidManifest.xml
    - Register service in manifest
    - Add FOREGROUND_SERVICE permission
    - _Requirements: 2.5_

  - [x] 12.3 Create Flutter method channel for foreground service
    - Create CastForegroundService Dart class
    - Implement start() and stop() methods using MethodChannel
    - Add to lib/services/cast_foreground_service.dart
    - _Requirements: 2.5_

  - [x] 12.4 Implement Kotlin method channel handler
    - Handle "startForegroundService" method call
    - Handle "stopForegroundService" method call
    - Add to MainActivity.kt
    - _Requirements: 2.5_

  - [x] 12.5 Write unit tests for foreground service integration
    - Test start() calls Android service
    - Test stop() calls Android service
    - _Requirements: 2.5_

- [x] 13. Implement FCM integration (Dart + Kotlin)
  - [x] 13.1 Add Firebase dependencies
    - Add firebase_core and firebase_messaging to pubspec.yaml
    - Add google-services.json to android/app/
    - Add Firebase plugin to android/build.gradle
    - _Requirements: 10.1_

  - [x] 13.2 Create CastFCMService class
    - Implement initialize() method (request permission, get token, register device)
    - Implement _registerDevice() method (POST /me/devices/register)
    - Listen for token refresh and re-register
    - Listen for foreground messages (type: "cast_job")
    - Listen for background messages
    - Add to lib/services/cast_fcm_service.dart
    - _Requirements: 10.1, 10.2, 10.3_

  - [x] 13.3 Implement background message handler
    - Create top-level function _handleBackgroundMessage
    - Check message type is "cast_job"
    - Wake up app to handle cast job
    - _Requirements: 3.3_

  - [x] 13.4 Write unit tests for FCM integration
    - Test initialize() requests permission
    - Test initialize() registers device
    - Test token refresh triggers re-registration
    - Test foreground message triggers handleFCMPush
    - _Requirements: 10.1, 10.2, 10.3_

- [x] 14. Integrate cast toggle in Settings
  - [x] 14.1 Add cast toggle to SettingsService
    - Add _keyCastToggleEnabled constant
    - Implement setCastToggleEnabled() method
    - Implement getCastToggleEnabled() method (default to enabled on TV, disabled elsewhere)
    - Add to lib/services/settings_service.dart
    - _Requirements: 8.2, 8.5_

  - [x] 14.2 Write property test for toggle state persistence
    - **Property 9: Toggle State Persistence**
    - **Validates: Requirements 8.5**

  - [x] 14.2 Add cast toggle UI to Settings screen
    - Add "Ready to Cast" toggle switch
    - Bind toggle to CastReceiverService.isCastEnabled
    - Call CastReceiverService.setCastEnabled() on toggle change
    - Show "Ready to Cast" indicator when enabled
    - Add to lib/screens/settings_screen.dart
    - _Requirements: 8.1, 8.3, 8.4_

  - [x] 14.3 Write unit tests for Settings integration
    - Test toggle state persists across app restarts
    - Test toggle enable starts polling
    - Test toggle disable stops polling
    - _Requirements: 8.3, 8.4, 8.5_

- [x] 15. Implement cast button UI on file preview cards
  - [x] 15.1 Add cast button to FilePreviewCard widget
    - Add cast icon button to card layout
    - Bind button enabled state to !CastService.isCasting(fileId)
    - Show "Casting..." indicator when isCasting is true
    - Hide cast button on TV devices (use TvDetectionService)
    - Only show cast button for video and audio files
    - Add to lib/widgets/file_preview_card.dart
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 15.2 Write property test for cast button visibility by media type
    - **Property 11: Cast Button Visibility by Media Type**
    - **Validates: Requirements 9.4**

  - [x] 15.2 Implement cast button onPressed handler
    - Call CastService.createCastJob() with file metadata
    - Show success toast "Cast sent to TV"
    - Show error toast on failure
    - Disable button during cast operation
    - _Requirements: 1.5, 1.6_

  - [x] 15.3 Write unit tests for cast button UI
    - Test cast button appears on video/audio files
    - Test cast button hidden on TV devices
    - Test cast button disabled during active cast
    - Test onPressed calls CastService.createCastJob
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

- [x] 16. Wire services together and initialize
  - [x] 16.1 Initialize CastService in main.dart
    - Create singleton instance of CastService
    - Inject Dio client and API base URL
    - Add to lib/main.dart
    - _Requirements: 1.1_

  - [x] 16.2 Initialize CastReceiverService in main.dart
    - Create singleton instance of CastReceiverService
    - Inject Dio client, API base URL, and SettingsService
    - Register as ChangeNotifier provider
    - Auto-start polling if cast toggle is enabled
    - Add to lib/main.dart
    - _Requirements: 2.1, 8.3_

  - [x] 16.3 Initialize CastFCMService in main.dart
    - Call CastFCMService.initialize() on app startup
    - Only initialize on Android devices
    - Add to lib/main.dart
    - _Requirements: 10.1_

  - [x] 16.4 Connect FCM push to CastReceiverService
    - In CastFCMService, call CastReceiverService.instance.handleFCMPush() when FCM message received
    - _Requirements: 3.3_

  - [x] 16.5 Write integration tests for service wiring
    - Test CastService singleton is accessible
    - Test CastReceiverService singleton is accessible
    - Test FCM initialization on Android
    - Test FCM push triggers CastReceiverService.handleFCMPush
    - _Requirements: 1.1, 2.1, 3.3, 10.1_

- [x] 17. Implement notification service for cast status
  - [x] 17.1 Create CastNotificationService class
    - Implement show() method to display Android notifications
    - Use flutter_local_notifications package
    - Create notification channel for cast status
    - Add to lib/services/cast_notification_service.dart
    - _Requirements: 5.5, 6.4_

  - [x] 17.2 Integrate notifications in CastReceiverService
    - Call CastNotificationService.show() for "Cast in progress..."
    - Call CastNotificationService.show() for "Now playing: {fileName}"
    - Call CastNotificationService.show() for error messages
    - _Requirements: 5.5, 6.4_

  - [x] 17.3 Write unit tests for notification service
    - Test show() displays notification
    - Test notification channel is created
    - _Requirements: 5.5, 6.4_

- [x] 18. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass (backend, Dart, integration), ask the user if questions arise.

- [x] 19. End-to-end integration testing
  - [x] 19.1 Write integration test for end-to-end cast flow
    - Sender creates job → Backend stores job → Receiver claims job → Playback starts
    - Verify job is removed after acknowledgment
    - _Requirements: 1.1, 2.1, 4.1, 7.1_

  - [x] 19.2 Write integration test for multi-device coordination
    - Multiple receivers polling → First to claim wins → Others receive 404
    - _Requirements: 12.1, 12.2_

  - [x] 19.3 Write integration test for FCM + long polling
    - Job created → FCM push sent → Receiver claims via FCM → Long polling request returns 204
    - _Requirements: 3.2, 3.3, 12.4_

  - [x] 19.4 Write integration test for network resilience
    - Disconnect network → Receiver retries with backoff → Reconnect → Polling resumes
    - _Requirements: 11.4_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation at key milestones
- Property tests validate universal correctness properties (30 properties total)
- Unit tests validate specific examples and edge cases
- Integration tests validate end-to-end flows and multi-component interactions
- The implementation assumes existing services (TelegramService, PlayerService, SettingsService, TvDetectionService) are available
- FCM integration is optional; the system falls back to long polling if FCM is unavailable
- All code examples in the design document should be used as reference during implementation
