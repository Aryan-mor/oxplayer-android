# FCM Integration Summary

## What Was Added

### 1. Dependencies
- **firebase.google.com/go/v4 v4.14.1** - Firebase Admin SDK for Go
- Added to `go.mod` and ready to use

### 2. FCM Client (`cast/fcm.go`)
- `NewFCMClient()` - Initializes FCM client with service account credentials
- `SendCastNotification()` - Sends push notification to a single device
- `SendCastNotificationToDevices()` - Sends push notifications to all registered devices for a user
- Supports two configuration methods:
  - `GOOGLE_APPLICATION_CREDENTIALS` environment variable (standard)
  - `FCM_CREDENTIALS_PATH` environment variable (custom)

### 3. Handler Integration (`cast/handlers.go`)
- Added `fcmClient` field to `Handler` struct
- Added `SetFCMClient()` method to optionally enable FCM
- Updated `handleCreateJob()` to send FCM notifications when jobs are created
- Notifications are sent asynchronously (non-blocking)

### 4. Main Server Integration (`main.go`)
- Added FCM client initialization on server startup
- Graceful degradation: if FCM is not configured, system uses long polling only
- Clear logging to indicate FCM status (enabled/disabled/error)

### 5. Documentation
- **FCM_SETUP.md** - Comprehensive setup guide with:
  - Step-by-step Firebase configuration
  - Security best practices
  - Troubleshooting guide
  - Production deployment checklist
- **README.md** - Updated with FCM integration overview
- **.env.example** - Example configuration file
- **.gitignore** - Ensures credentials are never committed

## How It Works

### Without FCM (Default)
1. TV polls `/me/cast/jobs/claim` every 30 seconds
2. When a job is created, the next poll returns it
3. Average latency: ~15 seconds

### With FCM (Optional)
1. TV registers FCM token via `/me/devices/register`
2. TV polls `/me/cast/jobs/claim` (as backup)
3. When a job is created:
   - Backend sends FCM push notification to all registered devices
   - TV receives push, immediately calls `/me/cast/jobs/claim`
   - First TV to claim gets the job
4. Average latency: <1 second

## Configuration Steps

### Development
```bash
# 1. Obtain Firebase credentials (see FCM_SETUP.md)
# 2. Save credentials file
cp ~/Downloads/serviceAccountKey.json server/firebase-serviceAccountKey.json

# 3. Set environment variable
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/server/firebase-serviceAccountKey.json"

# 4. Run server
cd server
go run main.go
```

### Production (Docker)
```yaml
# docker-compose.yml
services:
  relay-server:
    image: plezy-relay:latest
    environment:
      - GOOGLE_APPLICATION_CREDENTIALS=/secrets/firebase-credentials.json
    volumes:
      - ./firebase-credentials.json:/secrets/firebase-credentials.json:ro
    ports:
      - "8080:8080"
```

### Production (Kubernetes)
```yaml
# Create secret
kubectl create secret generic firebase-credentials \
  --from-file=serviceAccountKey.json=./firebase-serviceAccountKey.json

# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: relay-server
spec:
  template:
    spec:
      containers:
      - name: relay-server
        image: plezy-relay:latest
        env:
        - name: GOOGLE_APPLICATION_CREDENTIALS
          value: /secrets/firebase-credentials.json
        volumeMounts:
        - name: firebase-credentials
          mountPath: /secrets
          readOnly: true
      volumes:
      - name: firebase-credentials
        secret:
          secretName: firebase-credentials
```

## Testing FCM Integration

### 1. Start Server with FCM
```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/serviceAccountKey.json"
cd server
go run main.go
```

Expected output:
```
FCM client initialized successfully
FCM push notifications enabled
Starting relay server on :8080
```

### 2. Register a Device
```bash
curl -X POST http://localhost:8080/me/devices/register \
  -H "X-User-ID: test-user" \
  -H "Content-Type: application/json" \
  -d '{
    "deviceId": "test-device-123",
    "fcmToken": "fake-fcm-token-for-testing",
    "platform": "android",
    "appVersion": "1.0.0"
  }'
```

Expected response:
```json
{"registered": true}
```

### 3. Create a Cast Job
```bash
curl -X POST http://localhost:8080/me/cast/jobs \
  -H "X-User-ID: test-user" \
  -H "Content-Type: application/json" \
  -d '{
    "chatId": "123",
    "messageId": 456,
    "fileId": "test-file-id",
    "fileName": "test.mp4",
    "mimeType": "video/mp4",
    "totalBytes": 1024000
  }'
```

Check server logs for:
```
FCM notification sent successfully: projects/.../messages/...
```

## Security Checklist

- [ ] Firebase credentials file is NOT in version control
- [ ] Credentials file has restrictive permissions (chmod 600)
- [ ] Service account has minimal permissions (Firebase Cloud Messaging Admin only)
- [ ] Environment variables are set in production environment
- [ ] Credentials are stored in secret management system (production)
- [ ] Credential rotation schedule is established (every 90 days)
- [ ] Monitoring and alerting are configured

## Troubleshooting

### "FCM client not initialized"
**Cause:** Environment variable not set or credentials file not found

**Solution:**
```bash
# Check if variable is set
echo $GOOGLE_APPLICATION_CREDENTIALS

# Verify file exists and is readable
ls -la $GOOGLE_APPLICATION_CREDENTIALS
cat $GOOGLE_APPLICATION_CREDENTIALS | jq .
```

### "Failed to send FCM notification"
**Cause:** Invalid FCM token or network issues

**Solution:**
- Check server logs for detailed error message
- Verify the device registered successfully
- Test with a real device (not a fake token)

### Server logs show "FCM not configured"
**Cause:** This is expected if you haven't set up FCM yet

**Solution:**
- This is normal - the system works fine with long polling only
- To enable FCM, follow the setup guide in FCM_SETUP.md

## Next Steps

1. **For Development:**
   - System works out of the box with long polling
   - FCM is optional for development

2. **For Production:**
   - Follow FCM_SETUP.md to configure Firebase
   - Set up secret management for credentials
   - Configure monitoring and alerting

3. **For Testing:**
   - Use real Android devices with Firebase-enabled app
   - Test both FCM and long polling paths
   - Verify atomic job claiming with multiple devices

## References

- [FCM_SETUP.md](./FCM_SETUP.md) - Detailed setup guide
- [README.md](./README.md) - API documentation
- [Firebase Admin SDK](https://firebase.google.com/docs/admin/setup)
- [Firebase Cloud Messaging](https://firebase.google.com/docs/cloud-messaging)
