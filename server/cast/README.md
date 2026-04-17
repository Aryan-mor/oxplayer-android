# Cast Job Handler

This package implements the backend API for the Relay TV Cast feature.

## Features

- ✅ Cast job creation and storage
- ✅ Long polling for job delivery (30-second timeout)
- ✅ Atomic job claiming (first-come-first-served)
- ✅ Job acknowledgment (idempotent)
- ✅ Device registration for FCM push notifications
- ✅ FCM push notification support (optional)
- ✅ Automatic job expiration (5 minutes)

## Firebase Cloud Messaging (FCM) Integration

FCM enables instant push notifications to TV devices when cast jobs are created. **FCM is optional** - the system works perfectly with long polling alone, but FCM reduces latency from ~15 seconds to <1 second.

### Quick Setup

1. Obtain Firebase service account credentials (see [FCM_SETUP.md](./FCM_SETUP.md))
2. Set environment variable:
   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/serviceAccountKey.json"
   ```
3. Restart the server - FCM will be automatically enabled

### Configuration Options

- `GOOGLE_APPLICATION_CREDENTIALS`: Path to Firebase service account JSON (standard Google Cloud variable)
- `FCM_CREDENTIALS_PATH`: Alternative path to Firebase credentials (if you want to keep it separate)

If neither variable is set, the system will use long polling only (no FCM).

### Detailed Documentation

See [FCM_SETUP.md](./FCM_SETUP.md) for:
- Step-by-step Firebase setup
- Security best practices
- Troubleshooting guide
- Production deployment checklist

## Implemented Endpoints

### POST /me/cast/jobs

Creates a new cast job for the authenticated user.

**Authentication:**
- Requires `X-User-ID` header (placeholder for actual auth middleware)

**Request Body:**
```json
{
  "chatId": "string",
  "messageId": "number",
  "fileId": "string",
  "fileName": "string",
  "mimeType": "string",
  "totalBytes": "number",
  "thumbnailUrl": "string?" (optional),
  "metadata": {
    "title": "string?",
    "duration": "number?"
  } (optional)
}
```

**Response (201 Created):**
```json
{
  "jobId": "uuid",
  "createdAt": "RFC3339 timestamp"
}
```

**Error Responses:**
- `400 Bad Request`: Invalid payload or missing required fields
- `401 Unauthorized`: Missing or invalid auth token
- `405 Method Not Allowed`: Non-POST request
- `500 Internal Server Error`: Server error

**Validation Rules:**
- `chatId`: Required, non-empty string
- `messageId`: Required, non-zero integer
- `fileId`: Required, non-empty string
- `fileName`: Required, non-empty string
- `mimeType`: Required, non-empty string
- `totalBytes`: Required, must be greater than 0
- `thumbnailUrl`: Optional string
- `metadata`: Optional object

**Behavior:**
- Generates a unique UUID for each job
- Stores job in memory keyed by userId
- Overwrites any existing job for the same user
- Sends FCM push notifications to all registered devices (if FCM is configured)
- Returns job ID and creation timestamp

### GET /me/cast/jobs/claim

Claims the next available cast job for the authenticated user. Supports long polling.

**Authentication:**
- Requires `X-User-ID` header

**Query Parameters:**
- `timeout`: Optional, default 30 seconds, max 60 seconds

**Response (200 OK):**
```json
{
  "jobId": "uuid",
  "chatId": "string",
  "messageId": "number",
  "fileId": "string",
  "fileName": "string",
  "mimeType": "string",
  "totalBytes": "number",
  "thumbnailUrl": "string?",
  "metadata": {},
  "createdAt": "RFC3339 timestamp"
}
```

**Response (204 No Content):**
No job available (timeout expired or no job exists)

**Long Polling Behavior:**
- If a job exists, responds immediately with 200
- If no job exists, holds the request for up to `timeout` seconds
- If a job is created during the hold, responds immediately with 200
- If timeout expires with no job, responds with 204

**Atomic Claiming:**
- First receiver to claim gets the job (200 response)
- Subsequent claim attempts return 404 (job already claimed)

### POST /me/cast/jobs/:id/started

Acknowledges that playback has started for a cast job.

**Authentication:**
- Requires `X-User-ID` header

**Request Body:** Empty

**Response (200 OK):**
```json
{
  "acknowledged": true
}
```

**Behavior:**
- Idempotent: Always returns 200, even if job doesn't exist
- Removes job from memory (if it exists)

### POST /me/devices/register

Registers a device for FCM push notifications.

**Authentication:**
- Requires `X-User-ID` header

**Request Body:**
```json
{
  "deviceId": "string",
  "fcmToken": "string",
  "platform": "android",
  "appVersion": "string"
}
```

**Response (200 OK):**
```json
{
  "registered": true
}
```

**Validation Rules:**
- All fields are required
- `platform`: Currently only "android" is supported
- `fcmToken`: Must be a valid FCM registration token

**Behavior:**
- Stores device registration in memory (keyed by userId and deviceId)
- Overwrites existing registration for the same device
- In production, this should be stored in a database

## Testing

Run unit tests:
```bash
go test -v ./cast
```

Run tests with coverage:
```bash
go test -v -cover ./cast
```

## Architecture

### Data Stores

- **JobStore**: In-memory storage of cast jobs (map[userId]CastJob)
- **DeviceStore**: In-memory storage of device registrations (map[userId]map[deviceId]DeviceRegistration)

In production, these should be replaced with persistent storage (Redis, PostgreSQL, etc.)

### FCM Integration

- **FCMClient**: Wraps Firebase Cloud Messaging functionality
- Sends push notifications asynchronously (doesn't block HTTP responses)
- Gracefully degrades if FCM is not configured

### Job Expiration

- Background goroutine runs every 1 minute
- Removes jobs older than 5 minutes
- Prevents memory leaks from unclaimed jobs

## TODO

- Replace `X-User-ID` header with actual authentication middleware
- Replace in-memory stores with persistent storage (Redis/PostgreSQL)
- Add rate limiting for cast job creation (10 jobs/minute per user)
- Add metrics and monitoring (Prometheus)
- Add structured logging (zerolog/zap)
