# TV Cast Playback Not Starting - Bugfix Design

## Overview

The TV cast receiver successfully receives cast job data and acknowledges playback, but the video never actually starts playing. The `_handleCastJobReceived` callback in `main.dart` only logs the cast job details without initiating video playback. This bugfix implements the missing playback initialization logic to navigate to the video player screen and start playback automatically when a cast job is received.

The fix involves resolving the Telegram file metadata from the cast job data, creating a `TelegramVideoMetadata` object, obtaining a streaming URL from the backend, and navigating to the video player using the existing `navigateToInternalVideoPlayerForUrl` utility.

## Glossary

- **Bug_Condition (C)**: The condition that triggers the bug - when a cast job is received on the TV but playback is not initiated
- **Property (P)**: The desired behavior when a cast job is received - the video player should open and playback should start automatically
- **Preservation**: Existing cast job polling, logging, and acknowledgment behavior that must remain unchanged by the fix
- **_handleCastJobReceived**: The callback function in `main.dart` that processes received cast jobs
- **CastJobData**: The data structure containing cast job information (jobId, chatId, messageId, fileId, fileName, mimeType, totalBytes, thumbnailUrl, metadata)
- **TelegramVideoMetadata**: A `PlexMetadata` adapter for Telegram video files used by the video player
- **OxChatMediaRow**: The database row structure representing a Telegram media file
- **navigateToInternalVideoPlayerForUrl**: The utility function that navigates to the video player with a direct video URL
- **DataRepository**: The service that provides access to the backend API for resolving file metadata and streaming URLs

## Bug Details

### Bug Condition

The bug manifests when a cast job is received by the TV. The `_handleCastJobReceived` callback in `main.dart` logs the cast job details but does not navigate to the video player or initiate playback. The system acknowledges "playback started" to the backend without actually starting playback.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type CastJobData
  OUTPUT: boolean
  
  RETURN input.fileId IS NOT NULL
         AND input.chatId IS NOT NULL
         AND input.messageId IS NOT NULL
         AND videoPlayerNotOpened()
         AND playbackNotStarted()
END FUNCTION
```

### Examples

- **Example 1**: User casts "movie.mp4" from mobile to TV → TV receives cast job → TV logs "Ready to play movie.mp4 - playback implementation pending" → Video player does not open → Playback does not start
- **Example 2**: User casts a Telegram video with fileId="abc123" → TV receives cast job with all metadata → TV acknowledges playback started → Video player remains closed → User sees no visual feedback
- **Example 3**: User casts a video with chatId="456", messageId=789, fileId="xyz" → TV logs all details correctly → TV sends POST /me/cast/jobs/:id/started → Video player does not initialize → Playback never begins
- **Edge Case**: User casts a video while another video is playing → TV receives cast job → Current playback should stop → New video should start playing (expected behavior after fix)

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- Cast job polling mechanism with exponential backoff on errors must continue to work
- Cast job data parsing and logging must remain unchanged
- Acknowledgment to backend via POST /me/cast/jobs/:id/started must continue to be sent
- All cast job fields (jobId, chatId, messageId, fileId, fileName, mimeType, totalBytes, thumbnailUrl, metadata) must continue to be parsed correctly
- The onCastJobReceived callback invocation must continue to work

**Scope:**
All inputs that do NOT involve the video player initialization should be completely unaffected by this fix. This includes:
- Cast job polling and claiming logic
- Cast job data structure and parsing
- Backend acknowledgment mechanism
- Error handling and retry logic for polling
- Cast service initialization and lifecycle management

## Hypothesized Root Cause

Based on the bug description and code analysis, the root cause is clear:

1. **Missing Implementation**: The `_handleCastJobReceived` callback in `main.dart` contains a TODO comment indicating that video playback initiation is not implemented. The function only logs the cast job details and displays a debug message "Ready to play... - playback implementation pending".

2. **No Navigation Logic**: There is no code to navigate to the video player screen when a cast job is received.

3. **No Metadata Resolution**: The cast job contains Telegram file identifiers (chatId, messageId, fileId) but does not resolve these to the complete file metadata and streaming URL required by the video player.

4. **No Player Initialization**: The video player is never opened or initialized with the cast content.

## Correctness Properties

Property 1: Bug Condition - Cast Job Initiates Playback

_For any_ cast job received on the TV where the cast job contains valid Telegram file information (fileId, chatId, messageId), the fixed _handleCastJobReceived function SHALL resolve the file metadata, obtain a streaming URL, navigate to the video player screen, and start playback automatically.

**Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5**

Property 2: Preservation - Cast Job Processing

_For any_ cast job received, the fixed code SHALL continue to log the cast job details, parse the CastJobData correctly, and acknowledge playback to the backend, preserving all existing cast job processing behavior except for the addition of video player initialization.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5**

## Fix Implementation

### Changes Required

**File**: `oxplayer-android/lib/main.dart`

**Function**: `_handleCastJobReceived`

**Specific Changes**:

1. **Import Required Dependencies**:
   - Add import for `DataRepository` to resolve file metadata and streaming URLs
   - Add import for `TelegramVideoMetadata` to create metadata for the video player
   - Add import for `navigateToInternalVideoPlayerForUrl` to navigate to the player
   - Add import for `OxChatMediaRow` to construct the metadata row

2. **Create OxChatMediaRow from CastJobData**:
   - Construct an `OxChatMediaRow` object from the cast job data fields
   - Map `chatId`, `messageId`, `fileId`, `fileName`, `mimeType`, `totalBytes` to the row structure
   - Extract duration from metadata if available

3. **Create TelegramVideoMetadata**:
   - Instantiate `TelegramVideoMetadata` with the constructed `OxChatMediaRow`
   - Use `thumbnailUrl` from cast job data if available, otherwise use empty string

4. **Resolve Streaming URL**:
   - Create a `DataRepository` instance
   - Call `getInternalPlaybackUrl` with chatId, messageId, and fileId to obtain the streaming URL
   - Handle errors if URL resolution fails (log error and return early)

5. **Navigate to Video Player**:
   - Call `navigateToInternalVideoPlayerForUrl` with the root navigator context
   - Pass the `TelegramVideoMetadata` and resolved streaming URL
   - Use `rootNavigatorKey` to ensure navigation works from the main app context

6. **Error Handling**:
   - Wrap the entire implementation in try-catch to handle any errors gracefully
   - Log errors prominently using `appLogger.e` and `castDebugError`
   - Display error notification to user if playback fails to start
   - Continue polling for next cast job even if current job fails

7. **Acknowledgment Timing**:
   - Keep the acknowledgment call in `TvCastReceiverService._handleCastJob` after the callback
   - This ensures acknowledgment is sent after the player is opened (callback completes)

### Implementation Pseudocode

```dart
void _handleCastJobReceived(CastJobData jobData) async {
  appLogger.i('[Cast] TV: Received cast job - ${jobData.fileName}');
  castDebugSuccess('TV: Received cast job - ${jobData.fileName}');
  
  // Log the received job details for debugging (PRESERVED)
  appLogger.i('[Cast] TV: Cast job details:');
  castDebugInfo('TV: Cast job details:');
  castDebugInfo('  - File: ${jobData.fileName}');
  castDebugInfo('  - FileId: ${jobData.fileId}');
  castDebugInfo('  - ChatId: ${jobData.chatId}');
  castDebugInfo('  - MessageId: ${jobData.messageId}');
  castDebugInfo('  - MimeType: ${jobData.mimeType}');
  castDebugInfo('  - Size: ${jobData.totalBytes} bytes');
  castDebugInfo('  - Thumbnail: ${jobData.thumbnailUrl ?? "none"}');
  castDebugInfo('  - Metadata: ${jobData.metadata}');
  
  try {
    // 1. Create OxChatMediaRow from cast job data
    final row = OxChatMediaRow(
      chatId: jobData.chatId,
      messageId: jobData.messageId,
      fileId: jobData.fileId,
      fileName: jobData.fileName,
      mimeType: jobData.mimeType,
      fileSizeBytes: jobData.totalBytes,
      durationSeconds: jobData.metadata?['duration'] as int?,
      caption: jobData.metadata?['title'] as String?,
      messageDate: jobData.createdAt.toIso8601String(),
    );
    
    // 2. Create TelegramVideoMetadata
    final metadata = TelegramVideoMetadata(row, jobData.thumbnailUrl ?? '');
    
    // 3. Resolve streaming URL from backend
    appLogger.i('[Cast] TV: Resolving streaming URL for fileId=${jobData.fileId}');
    castDebugInfo('TV: Resolving streaming URL for fileId=${jobData.fileId}');
    
    final repo = await DataRepository.create();
    final chatIdInt = int.parse(jobData.chatId);
    final streamUrl = await repo.getInternalPlaybackUrl(
      chatId: chatIdInt,
      messageId: jobData.messageId,
      fileId: jobData.fileId,
    );
    
    if (streamUrl == null || streamUrl.isEmpty) {
      throw Exception('Failed to resolve streaming URL');
    }
    
    appLogger.i('[Cast] TV: Streaming URL resolved: $streamUrl');
    castDebugSuccess('TV: Streaming URL resolved');
    
    // 4. Navigate to video player
    appLogger.i('[Cast] TV: Opening video player for ${jobData.fileName}');
    castDebugSuccess('TV: Opening video player for ${jobData.fileName}');
    
    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      throw Exception('Root navigator context not available');
    }
    
    await navigateToInternalVideoPlayerForUrl(
      context,
      metadata: metadata,
      videoUrl: streamUrl,
    );
    
    appLogger.i('[Cast] TV: Video player opened successfully');
    castDebugSuccess('TV: Video player opened successfully');
    
  } catch (e, stackTrace) {
    appLogger.e('[Cast] TV: Failed to start playback for cast job', error: e, stackTrace: stackTrace);
    castDebugError('TV: Failed to start playback: $e');
    
    // Show error notification to user
    final context = rootNavigatorKey.currentContext;
    if (context != null) {
      showErrorSnackBar(context, 'Cast playback failed: ${e.toString()}');
    }
  }
}
```

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bug on unfixed code, then verify the fix works correctly and preserves existing behavior.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bug BEFORE implementing the fix. Confirm that the video player does not open when a cast job is received.

**Test Plan**: Manually test the cast flow on unfixed code by sending a cast job from mobile to TV and observing that the video player does not open. Run these tests on the UNFIXED code to observe failures and confirm the root cause.

**Test Cases**:
1. **Basic Cast Test**: Send a cast job for a simple video file from mobile to TV (will fail on unfixed code - player does not open)
2. **Cast with Metadata Test**: Send a cast job with title and duration metadata (will fail on unfixed code - player does not open)
3. **Cast with Thumbnail Test**: Send a cast job with a thumbnail URL (will fail on unfixed code - player does not open)
4. **Multiple Cast Test**: Send multiple cast jobs in sequence (will fail on unfixed code - no playback for any job)

**Expected Counterexamples**:
- Video player screen does not open when cast job is received
- Debug logs show "Ready to play... - playback implementation pending"
- TV acknowledges playback started but no actual playback occurs
- Possible causes: missing navigation logic, missing metadata resolution, missing player initialization

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds, the fixed function produces the expected behavior.

**Pseudocode:**
```
FOR ALL castJob WHERE isBugCondition(castJob) DO
  result := _handleCastJobReceived_fixed(castJob)
  ASSERT videoPlayerOpened(result)
  ASSERT playbackStarted(result)
  ASSERT streamingUrlResolved(result)
END FOR
```

**Test Plan**: After implementing the fix, test the cast flow by sending cast jobs from mobile to TV and verifying that:
1. The video player screen opens
2. Playback starts automatically
3. The correct video is playing
4. The video metadata is displayed correctly

**Test Cases**:
1. **Basic Cast Test**: Send a cast job for a simple video file → Verify player opens and playback starts
2. **Cast with Metadata Test**: Send a cast job with title and duration → Verify metadata is displayed in player
3. **Cast with Thumbnail Test**: Send a cast job with thumbnail → Verify thumbnail is shown before playback
4. **Cast During Playback Test**: Send a cast job while another video is playing → Verify current playback stops and new video starts
5. **Cast Error Handling Test**: Send a cast job with invalid fileId → Verify error is logged and user sees error message

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed function produces the same result as the original function.

**Pseudocode:**
```
FOR ALL castJob WHERE NOT isBugCondition(castJob) DO
  ASSERT _handleCastJobReceived_original(castJob) = _handleCastJobReceived_fixed(castJob)
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many test cases automatically across the input domain
- It catches edge cases that manual unit tests might miss
- It provides strong guarantees that behavior is unchanged for all non-buggy inputs

**Test Plan**: Observe behavior on UNFIXED code first for cast job polling, logging, and acknowledgment, then write property-based tests capturing that behavior.

**Test Cases**:
1. **Cast Job Logging Preservation**: Observe that cast job details are logged correctly on unfixed code, then verify this continues after fix
2. **Cast Job Parsing Preservation**: Observe that CastJobData is parsed correctly on unfixed code, then verify this continues after fix
3. **Acknowledgment Preservation**: Observe that POST /me/cast/jobs/:id/started is sent on unfixed code, then verify this continues after fix
4. **Polling Preservation**: Observe that polling continues after processing a cast job on unfixed code, then verify this continues after fix
5. **Error Handling Preservation**: Observe that polling errors are handled with exponential backoff on unfixed code, then verify this continues after fix

### Unit Tests

- Test OxChatMediaRow creation from CastJobData
- Test TelegramVideoMetadata creation from OxChatMediaRow
- Test streaming URL resolution with valid chatId, messageId, fileId
- Test error handling when streaming URL resolution fails
- Test navigation to video player with valid metadata and URL
- Test error handling when navigation context is not available

### Property-Based Tests

- Generate random CastJobData objects and verify that video player opens for all valid inputs
- Generate random error scenarios (invalid fileId, network errors) and verify error handling works correctly
- Generate random cast job sequences and verify that each job is processed independently
- Test that all cast job fields are preserved during metadata conversion

### Integration Tests

- Test full cast flow from mobile to TV with real backend
- Test cast flow with different video types (short videos, long videos, videos with metadata)
- Test cast flow with different network conditions (slow network, intermittent connectivity)
- Test cast flow with multiple TV devices (ensure only one TV claims the job)
- Test cast flow with TV in different states (idle, playing video, in menu)
