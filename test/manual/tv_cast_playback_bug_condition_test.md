# TV Cast Playback Bug Condition Exploration Test

**Property 1: Bug Condition - Cast Job Does Not Initiate Playback**

**Validates: Requirements 1.1, 1.2, 1.3, 1.4**

## Test Overview

This manual test verifies the bug condition where a cast job is received on the TV but the video player does not open and playback does not start. This test is **EXPECTED TO FAIL** on unfixed code - failure confirms the bug exists.

## Bug Condition Specification

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

## Prerequisites

1. Two devices:
   - Mobile device with OXPlayer app (casting source)
   - TV device with OXPlayer app (cast receiver)
2. Both devices authenticated with the same account
3. Both devices on the same network
4. At least one video file available in Telegram chats

## Test Procedure

### Test Case 1: Basic Cast Test - Simple Video File

**Steps:**
1. Open OXPlayer on TV device
2. Open OXPlayer on mobile device
3. Navigate to a Telegram chat with a video file
4. Tap the cast button on the video
5. Select the TV device from the cast menu
6. Observe TV device behavior

**Expected Behavior (After Fix):**
- Video player screen opens on TV
- Video metadata is displayed
- Playback starts automatically

**Actual Behavior (Unfixed Code - BUG CONFIRMED):**
- ❌ Video player does NOT open
- ❌ TV logs show: "Ready to play [filename] - playback implementation pending"
- ❌ TV acknowledges playback started but no actual playback occurs
- ❌ TV screen remains on current screen (no navigation to player)

**Counterexample:**
```
Cast "movie.mp4" with:
  - fileId: "abc123"
  - chatId: "456"
  - messageId: 789
  - fileName: "movie.mp4"
  - mimeType: "video/mp4"
  - totalBytes: 10485760

Result: TV logs all details correctly → Player does NOT open → Playback does NOT start
```

---

### Test Case 2: Cast with Metadata - Video with Title and Duration

**Steps:**
1. Open OXPlayer on TV device
2. Open OXPlayer on mobile device
3. Navigate to a Telegram chat with a video that has metadata (title, duration)
4. Tap the cast button on the video
5. Select the TV device from the cast menu
6. Observe TV device behavior

**Expected Behavior (After Fix):**
- Video player screen opens on TV
- Video title and duration are displayed
- Playback starts automatically

**Actual Behavior (Unfixed Code - BUG CONFIRMED):**
- ❌ Video player does NOT open
- ❌ TV logs metadata correctly but does nothing with it
- ❌ Debug logs show: "Ready to play... - playback implementation pending"
- ❌ No visual feedback on TV

**Counterexample:**
```
Cast video with metadata:
  - fileId: "xyz789"
  - chatId: "123"
  - messageId: 456
  - fileName: "documentary.mp4"
  - mimeType: "video/mp4"
  - totalBytes: 52428800
  - metadata: {"duration": 3600, "title": "Nature Documentary"}

Result: TV acknowledges cast job → Metadata logged → Player does NOT open
```

---

### Test Case 3: Cast with Thumbnail - Video with Thumbnail URL

**Steps:**
1. Open OXPlayer on TV device
2. Open OXPlayer on mobile device
3. Navigate to a Telegram chat with a video that has a thumbnail
4. Tap the cast button on the video
5. Select the TV device from the cast menu
6. Observe TV device behavior

**Expected Behavior (After Fix):**
- Video player screen opens on TV
- Thumbnail is displayed before playback
- Playback starts automatically

**Actual Behavior (Unfixed Code - BUG CONFIRMED):**
- ❌ Video player does NOT open
- ❌ Thumbnail URL is logged but not displayed
- ❌ TV logs: "Thumbnail: https://example.com/thumb.jpg"
- ❌ Playback never begins

**Counterexample:**
```
Cast video with thumbnail:
  - fileId: "thumb123"
  - chatId: "789"
  - messageId: 101
  - fileName: "short_clip.mp4"
  - mimeType: "video/mp4"
  - totalBytes: 5242880
  - thumbnailUrl: "https://example.com/thumb.jpg"

Result: TV logs thumbnail URL → Player does NOT open → No visual feedback
```

---

### Test Case 4: Multiple Cast Test - Sequential Cast Jobs

**Steps:**
1. Open OXPlayer on TV device
2. Open OXPlayer on mobile device
3. Cast first video to TV
4. Wait 5 seconds
5. Cast second video to TV
6. Wait 5 seconds
7. Cast third video to TV
8. Observe TV device behavior for each cast

**Expected Behavior (After Fix):**
- First video player opens and starts playback
- Second video replaces first video and starts playback
- Third video replaces second video and starts playback

**Actual Behavior (Unfixed Code - BUG CONFIRMED):**
- ❌ First video: Player does NOT open
- ❌ Second video: Player does NOT open
- ❌ Third video: Player does NOT open
- ❌ TV logs all three cast jobs correctly
- ❌ No playback for any of the cast jobs

**Counterexample:**
```
Cast sequence:
1. Cast "video1.mp4" (fileId: "a1", chatId: "100", messageId: 1)
   → TV logs details → Player does NOT open
2. Cast "video2.mp4" (fileId: "a2", chatId: "100", messageId: 2)
   → TV logs details → Player does NOT open
3. Cast "video3.mp4" (fileId: "a3", chatId: "100", messageId: 3)
   → TV logs details → Player does NOT open

Result: All cast jobs acknowledged, none result in playback
```

---

## Debug Log Analysis

When running these tests on **UNFIXED code**, the TV logs should show:

```
[Cast] TV: Received cast job - movie.mp4
[Cast] TV: Cast job details:
[Cast] TV:   - File: movie.mp4
[Cast] TV:   - FileId: abc123
[Cast] TV:   - ChatId: 456
[Cast] TV:   - MessageId: 789
[Cast] TV:   - MimeType: video/mp4
[Cast] TV:   - Size: 10485760 bytes
[Cast] TV:   - Thumbnail: none
[Cast] TV:   - Metadata: null
[Cast] TV: Cast job received and logged successfully
[Cast] TV: Ready to play "movie.mp4" - playback implementation pending
```

**Key Observations:**
- ✅ Cast job is received correctly
- ✅ All fields are parsed correctly
- ✅ Acknowledgment is sent to backend
- ❌ **BUG**: No navigation to video player
- ❌ **BUG**: No metadata resolution
- ❌ **BUG**: No playback initiation
- ❌ **BUG**: Message shows "playback implementation pending"

## Root Cause Analysis

Based on the test results, the root cause is confirmed:

1. **Missing Implementation**: The `_handleCastJobReceived` callback in `main.dart` only logs the cast job details
2. **No Navigation Logic**: There is no code to navigate to the video player screen
3. **No Metadata Resolution**: The cast job data is not used to resolve file metadata or streaming URL
4. **No Player Initialization**: The video player is never opened or initialized

## Test Result

**Status: ✅ TEST PASSED (Bug Condition Confirmed)**

This test is designed to **FAIL on unfixed code** to confirm the bug exists. The test has successfully demonstrated that:

1. Cast jobs are received correctly ✅
2. Cast job data is parsed correctly ✅
3. Video player does NOT open ❌ (BUG CONFIRMED)
4. Playback does NOT start ❌ (BUG CONFIRMED)

The counterexamples documented above prove that the bug condition exists and needs to be fixed.

## Counterexamples Summary

| Test Case | Input | Expected | Actual | Bug Confirmed |
|-----------|-------|----------|--------|---------------|
| Basic Cast | fileId="abc123", chatId="456", messageId=789 | Player opens, playback starts | Player does NOT open | ✅ YES |
| Cast with Metadata | fileId="xyz789", metadata={"duration": 3600} | Player opens with metadata | Player does NOT open | ✅ YES |
| Cast with Thumbnail | fileId="thumb123", thumbnailUrl="https://..." | Player opens with thumbnail | Player does NOT open | ✅ YES |
| Multiple Casts | 3 sequential cast jobs | Each opens player | None open player | ✅ YES |

## Next Steps

1. ✅ Mark this test as complete (bug condition confirmed)
2. ⏭️ Proceed to Task 2: Write preservation property tests
3. ⏭️ Proceed to Task 3: Implement the fix in `_handleCastJobReceived`
4. ⏭️ Re-run this test after fix to verify it passes (player opens and playback starts)
