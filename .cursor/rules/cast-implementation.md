# Cast Implementation Rules

## Overview
The cast system allows mobile devices to send video playback commands to TV devices using the same Telegram account. Both devices share the same backend session, so the TV can access the same Telegram content.

## Architecture

### Cast Flow
1. **Mobile Device**: Creates a cast job via backend API with Telegram file metadata (chatId, messageId, fileId)
2. **Backend**: Stores the cast job and makes it available for polling
3. **TV Device**: Polls for cast jobs, receives the metadata, resolves the streaming URL, and starts playback

### Key Components

#### Mobile Side (Cast Sender)
- **FilePreviewCard**: Widget that displays file information and cast button
- **CastService**: Service that creates cast jobs via backend API
- Cast metadata required:
  - `castChatId`: Telegram chat ID (numeric, as string)
  - `castMessageId`: Telegram message ID (numeric)
  - `castFileId`: Telegram file ID or remote file ID
  - `castFileName`: Display name for the file
  - `castMimeType`: MIME type (e.g., "video/mp4")
  - `castTotalBytes`: File size in bytes
  - `castThumbnailUrl`: Optional thumbnail URL

#### TV Side (Cast Receiver)
- **TvCastReceiverService**: Polls backend for cast jobs
- **_handleCastJobReceived**: Callback in main.dart that processes cast jobs
- Processing steps:
  1. Parse cast job data (chatId, messageId, fileId)
  2. Create OxChatMediaRow and TelegramVideoMetadata
  3. Resolve streaming URL using DataRepository
  4. Navigate to video player with metadata and URL

## Critical Rules

### 1. Always Pass Telegram Locator Information
When creating FilePreviewCard for Telegram-sourced content, ALWAYS pass the locator fields:

```dart
FilePreviewCard(
  // ... other fields ...
  castChatId: file.locatorChatId?.toString(),  // REQUIRED for Telegram content
  castMessageId: file.locatorMessageId,         // REQUIRED for Telegram content
  castFileId: file.telegramFileId ?? file.locatorRemoteFileId,  // REQUIRED
  castFileName: fileName,
  castMimeType: 'video/mp4',
  castTotalBytes: file.size,
  castThumbnailUrl: thumbnailUrl,
)
```

### 2. Never Use Fallback Values for Telegram Content
The fallback values in FilePreviewCard (`'ox-plex-content'`, `1`, etc.) are ONLY for non-Telegram content. For Telegram content, the actual locator values MUST be passed.

### 3. TV Must Parse chatId as Integer
The TV receiver expects `chatId` to be a numeric Telegram chat ID. It will call `int.parse(jobData.chatId)` to resolve the streaming URL via TDLib.

### 4. Use Correct URL Resolution Method
For Telegram content, always use:
```dart
repo.resolveTelegramChatMessageStreamUrlForPlayback(
  chatId: int.parse(jobData.chatId),
  messageId: jobData.messageId,
)
```

### 5. Both Devices Share Same Account
Since mobile and TV use the same Telegram account:
- TV can access any Telegram content the mobile device can access
- No need to transfer file data - just send the locator (chatId, messageId, fileId)
- TV resolves the streaming URL using its own TDLib session

## Common Issues

### Issue: "FormatException: Invalid radix-10 number"
**Cause**: chatId is not a valid integer (e.g., "ox-plex-content")
**Solution**: Ensure FilePreviewCard receives proper `castChatId` from `file.locatorChatId`

### Issue: Cast job created but TV doesn't start playback
**Cause**: Missing or incorrect locator information in cast job
**Solution**: Verify all cast metadata fields are populated correctly

### Issue: TV acknowledges but video doesn't play
**Cause**: Streaming URL resolution failed
**Solution**: Check that chatId and messageId are valid and the file is accessible via TDLib

## File Locations

### Mobile (Cast Sender)
- `lib/widgets/file_preview_card.dart` - Cast button and metadata
- `lib/services/cast_service.dart` - Cast job creation
- `lib/screens/media_detail_screen.dart` - Library media casting
- `lib/screens/telegram/my_telegram_video_detail_screen.dart` - My Telegram casting

### TV (Cast Receiver)
- `lib/main.dart` - `_handleCastJobReceived` callback
- `lib/services/tv_cast_receiver_service.dart` - Cast job polling

### Shared
- `lib/infrastructure/data_repository.dart` - URL resolution methods
- `lib/infrastructure/media_repository.dart` - Media playback utilities

## Testing Checklist

When implementing or modifying cast functionality:

- [ ] Verify castChatId is passed for all Telegram content sources
- [ ] Verify castChatId is a valid numeric Telegram chat ID
- [ ] Test casting from "My Telegram" screen
- [ ] Test casting from library media screen (Telegram-sourced)
- [ ] Verify TV receives correct chatId (not "ox-plex-content")
- [ ] Verify TV can parse chatId as integer
- [ ] Verify streaming URL is resolved successfully
- [ ] Verify video player opens and playback starts
- [ ] Check error handling for invalid cast jobs
- [ ] Verify acknowledgment is sent after player opens
