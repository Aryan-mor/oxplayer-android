# Requirements Document

## Introduction

The Relay TV Cast feature enables users to send media from their mobile or tablet device to their TV using a relay-based architecture. Unlike traditional casting protocols (Chromecast, AirPlay), this system uses a backend relay server to coordinate the handoff between sender and receiver devices. The sender posts a cast job to the backend, the TV polls for jobs, and once claimed, the TV plays the media directly from the source.

## Glossary

- **Sender**: The mobile or tablet OxPlayer application that initiates a cast operation
- **Receiver**: The TV OxPlayer application that receives and plays cast media
- **Cast_Job**: A data structure containing media playback information (chatId, messageId, fileId, etc.) stored on the backend
- **Backend**: The OxPlayer API server that relays cast jobs between sender and receiver
- **Long_Polling**: An HTTP technique where the server holds a request open until data is available or a timeout occurs
- **FCM**: Firebase Cloud Messaging, a push notification service for instant delivery
- **Peer_Hydration**: The process of resolving a fileId to peer connection information and file metadata before playback
- **Cast_Toggle**: A user setting on the TV that enables or disables the receiver functionality
- **Claim_Operation**: An atomic operation where the first TV to request a cast job receives it exclusively

## Requirements

### Requirement 1: Cast Job Creation

**User Story:** As a mobile user, I want to cast media to my TV, so that I can watch content on a larger screen.

#### Acceptance Criteria

1. WHEN the user taps the cast button on a file preview card, THE Sender SHALL send a POST request to /me/cast/jobs with the media payload (chatId, messageId, fileId, and other playback metadata)
2. THE Backend SHALL store the cast job in an in-memory data structure keyed by userId
3. WHEN the cast job is successfully created, THE Backend SHALL return HTTP 201 with the job ID
4. IF the cast job creation fails, THEN THE Backend SHALL return an appropriate error code (400 for invalid payload, 500 for server error)
5. THE Sender SHALL display a confirmation message when the cast job is created successfully
6. THE Sender SHALL display an error message when the cast job creation fails

### Requirement 2: Cast Job Polling

**User Story:** As a TV user, I want my TV to automatically receive cast requests, so that I don't have to manually check for new content.

#### Acceptance Criteria

1. WHERE the cast toggle is enabled, THE Receiver SHALL initiate a long polling request to GET /me/cast/jobs/claim with a 30-second timeout
2. WHEN a long polling request times out without receiving a job, THE Receiver SHALL immediately initiate a new long polling request
3. WHEN a long polling request fails with a network error, THE Receiver SHALL retry with exponential backoff (starting at 1 second, doubling up to 60 seconds maximum)
4. WHEN a long polling request fails with HTTP 401, THE Receiver SHALL stop polling and display an authentication error
5. WHILE the Receiver is polling, THE Receiver SHALL maintain a foreground service to prevent Android Doze mode from terminating the connection
6. WHEN the cast toggle is disabled, THE Receiver SHALL cancel all active polling requests and stop the foreground service

### Requirement 3: Cast Job Delivery

**User Story:** As a TV user, I want to receive cast jobs instantly, so that playback starts without delay.

#### Acceptance Criteria

1. WHEN a cast job exists for a user, THE Backend SHALL immediately respond to any active long polling request from that user's receiver with HTTP 200 and the job payload
2. WHERE FCM is available, THE Backend SHALL send a push notification to all registered receiver devices when a cast job is created
3. WHEN a receiver receives an FCM notification, THE Receiver SHALL immediately call GET /me/cast/jobs/claim to retrieve the job
4. THE Backend SHALL deliver the same cast job to all polling receivers until one receiver claims it
5. WHEN multiple receivers are polling, THE Backend SHALL respond to all active requests simultaneously (broadcast-style delivery)

### Requirement 4: Cast Job Claiming

**User Story:** As a TV user, I want only one TV to play the cast content, so that multiple TVs don't play the same content simultaneously.

#### Acceptance Criteria

1. WHEN a receiver calls GET /me/cast/jobs/claim, THE Backend SHALL atomically assign the job to that receiver and remove it from the available jobs
2. WHEN the first receiver claims a job, THE Backend SHALL return HTTP 200 with the job payload
3. WHEN a subsequent receiver attempts to claim the same job, THE Backend SHALL return HTTP 404 (job not found)
4. THE Backend SHALL ensure that only one receiver can successfully claim a given cast job (atomic claim operation)
5. WHEN a receiver successfully claims a job, THE Receiver SHALL store the job ID for acknowledgment

### Requirement 5: Peer Hydration

**User Story:** As a TV user, I want the TV to resolve file metadata before opening the player, so that playback doesn't fail with connection errors.

#### Acceptance Criteria

1. WHEN a receiver claims a cast job, THE Receiver SHALL resolve the fileId to peer connection information and file metadata before opening the player
2. THE Receiver SHALL retrieve the totalBytes, mimeType, and peer connection details for the file
3. IF peer hydration fails, THEN THE Receiver SHALL display an error notification and SHALL NOT open the player
4. WHEN peer hydration succeeds, THE Receiver SHALL pass the hydrated metadata to the player
5. WHILE peer hydration is in progress, THE Receiver SHALL display a "Cast in progress..." notification

### Requirement 6: Playback Preemption

**User Story:** As a TV user, I want incoming cast jobs to take priority over current playback, so that the cast content starts immediately.

#### Acceptance Criteria

1. WHEN a receiver claims a cast job, THE Receiver SHALL immediately stop any currently playing media
2. WHEN a receiver claims a cast job, THE Receiver SHALL cancel any queued playback operations
3. THE Receiver SHALL open the player with the cast job's media after stopping current playback
4. THE Receiver SHALL display a brief notification indicating that playback was preempted by a cast operation

### Requirement 7: Cast Job Acknowledgment

**User Story:** As a system, I want to remove cast jobs once playback starts, so that the backend doesn't hold stale data.

#### Acceptance Criteria

1. WHEN the receiver successfully starts playback, THE Receiver SHALL send a POST request to /me/cast/jobs/:id/started
2. WHEN the backend receives an acknowledgment for an existing job, THE Backend SHALL remove the job from memory and return HTTP 200
3. WHEN the backend receives an acknowledgment for a non-existent job, THE Backend SHALL return HTTP 200 (idempotent acknowledgment)
4. IF the acknowledgment request fails, THEN THE Receiver SHALL retry up to 3 times with exponential backoff
5. THE Receiver SHALL not block playback waiting for acknowledgment success

### Requirement 8: Cast Toggle Setting

**User Story:** As a TV user, I want to control whether my TV receives cast requests, so that I can disable casting when not needed.

#### Acceptance Criteria

1. THE Receiver SHALL provide a "Ready to Cast" toggle in the Settings screen
2. THE Cast_Toggle SHALL default to enabled (ON) for new installations
3. WHEN the user enables the cast toggle, THE Receiver SHALL start the polling service and display a "Ready to Cast" indicator
4. WHEN the user disables the cast toggle, THE Receiver SHALL stop the polling service and hide the "Ready to Cast" indicator
5. THE Receiver SHALL persist the cast toggle state across app restarts

### Requirement 9: Cast Button UI

**User Story:** As a mobile user, I want a visible cast button on media cards, so that I can easily initiate casting.

#### Acceptance Criteria

1. THE Sender SHALL display a cast button (cast icon) on file preview cards
2. WHEN no cast job is in progress, THE Sender SHALL enable the cast button
3. WHEN a cast job is in progress for the current file, THE Sender SHALL disable the cast button and display a "Casting..." indicator
4. THE Sender SHALL display the cast button only on supported media types (video and audio files)
5. ON TV devices, THE Sender SHALL hide the cast button (casting from TV to TV is not supported)

### Requirement 10: FCM Token Registration

**User Story:** As a TV user, I want my TV to register for push notifications, so that cast jobs arrive instantly.

#### Acceptance Criteria

1. WHERE FCM is available, THE Receiver SHALL register for FCM push notifications on app startup
2. WHEN an FCM token is obtained, THE Receiver SHALL send it to POST /me/devices/register with device metadata (deviceId, platform, appVersion)
3. WHEN the FCM token is refreshed, THE Receiver SHALL update the backend with the new token
4. THE Backend SHALL store the FCM token associated with the user's account and device
5. WHERE FCM is unavailable, THE Receiver SHALL rely solely on long polling for job delivery

### Requirement 11: Error Handling and Resilience

**User Story:** As a user, I want the cast system to handle errors gracefully, so that temporary failures don't break the feature.

#### Acceptance Criteria

1. WHEN the backend is unreachable, THE Sender SHALL display a "Cast service unavailable" error
2. WHEN the backend is unreachable, THE Receiver SHALL continue retrying with exponential backoff up to 60 seconds
3. IF peer hydration fails due to a network error, THEN THE Receiver SHALL retry up to 3 times before displaying an error
4. WHEN the receiver loses network connectivity, THE Receiver SHALL automatically resume polling when connectivity is restored
5. THE Backend SHALL automatically remove cast jobs older than 5 minutes to prevent stale job accumulation

### Requirement 12: Multi-Device Coordination

**User Story:** As a user with multiple TVs, I want any TV to be able to receive cast jobs, so that I can cast to whichever TV is convenient.

#### Acceptance Criteria

1. WHEN multiple receivers are polling for the same user, THE Backend SHALL deliver the cast job to all active receivers
2. WHEN the first receiver claims the job, THE Backend SHALL ensure subsequent claim attempts return HTTP 404
3. THE Backend SHALL support multiple concurrent polling connections per user (one per receiver device)
4. WHEN a receiver claims a job, THE Backend SHALL immediately respond to other pending polling requests with HTTP 204 (no job available)
5. THE Receiver SHALL handle HTTP 204 responses by immediately re-polling

