# Bugfix Requirements Document

## Introduction

The TV cast receiver successfully receives cast job data from the casting device and acknowledges the playback, but the video never actually starts playing. The cast job polling mechanism works correctly, the job data is received and logged, and the system sends an acknowledgment to the backend. However, the `_handleCastJobReceived` callback in `main.dart` only logs the cast job details without initiating video playback. This results in the TV displaying "Ready to play... - playback implementation pending" instead of starting the video.

This bugfix ensures that when a cast job is received on the TV, the video player is properly initialized and playback begins automatically.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN a cast job is received by the TV THEN the system logs the cast job details but does not navigate to the video player

1.2 WHEN a cast job is received by the TV THEN the system acknowledges "playback started" to the backend without actually starting playback

1.3 WHEN a cast job is received by the TV THEN the system displays "Ready to play... - playback implementation pending" instead of playing the video

1.4 WHEN a cast job contains valid video file information (fileId, chatId, messageId) THEN the system does not resolve the file metadata or initialize the video player

### Expected Behavior (Correct)

2.1 WHEN a cast job is received by the TV THEN the system SHALL navigate to the video player screen with the cast content

2.2 WHEN a cast job is received by the TV THEN the system SHALL resolve the file metadata (peer connection, totalBytes, mimeType) before starting playback

2.3 WHEN a cast job is received by the TV THEN the system SHALL initialize the video player with the resolved file metadata and start playback automatically

2.4 WHEN a cast job contains valid video file information (fileId, chatId, messageId) THEN the system SHALL hydrate the peer connection and pass the complete file information to the video player

2.5 WHEN playback is successfully initiated THEN the system SHALL acknowledge "playback started" to the backend only after the player has been opened

### Unchanged Behavior (Regression Prevention)

3.1 WHEN a cast job is received THEN the system SHALL CONTINUE TO log the cast job details for debugging purposes

3.2 WHEN a cast job is received THEN the system SHALL CONTINUE TO acknowledge playback to the backend via POST /me/cast/jobs/:id/started

3.3 WHEN the TV is polling for cast jobs THEN the system SHALL CONTINUE TO use the existing polling mechanism with exponential backoff on errors

3.4 WHEN a cast job is received THEN the system SHALL CONTINUE TO parse the CastJobData correctly (jobId, chatId, messageId, fileId, fileName, mimeType, totalBytes, thumbnailUrl, metadata)

3.5 WHEN the onCastJobReceived callback is invoked THEN the system SHALL CONTINUE TO receive the complete CastJobData object with all fields populated
