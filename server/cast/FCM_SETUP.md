# Firebase Cloud Messaging (FCM) Setup Guide

This guide explains how to configure Firebase Cloud Messaging for the Relay TV Cast feature.

## Overview

FCM enables instant push notifications to TV devices when cast jobs are created. Without FCM, the system relies solely on long polling (30-second intervals), which works but has higher latency.

**FCM is optional** - the cast system will work without it, but with slightly delayed delivery.

## Prerequisites

1. A Firebase project (create one at https://console.firebase.google.com/)
2. Admin access to the Firebase project
3. The backend server must have network access to Firebase APIs

## Step 1: Obtain Service Account Credentials

1. Go to the [Firebase Console](https://console.firebase.google.com/)
2. Select your project (or create a new one)
3. Click the gear icon (⚙️) next to "Project Overview" → **Project Settings**
4. Navigate to the **Service Accounts** tab
5. Click **Generate New Private Key**
6. Click **Generate Key** in the confirmation dialog
7. A JSON file will be downloaded - **save it securely**

**⚠️ SECURITY WARNING:**
- This JSON file contains sensitive credentials
- **NEVER commit it to version control** (add to .gitignore)
- Store it in a secure location with restricted file permissions
- Rotate the key periodically for security

## Step 2: Configure the Backend Server

There are two ways to configure FCM credentials:

### Option A: Environment Variable (Recommended for Production)

Set the `GOOGLE_APPLICATION_CREDENTIALS` environment variable to the path of your service account JSON file:

```bash
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/serviceAccountKey.json"
```

For Docker deployments, mount the credentials file and set the environment variable:

```yaml
# docker-compose.yml
services:
  relay-server:
    image: plezy-relay:latest
    environment:
      - GOOGLE_APPLICATION_CREDENTIALS=/secrets/firebase-credentials.json
    volumes:
      - ./firebase-credentials.json:/secrets/firebase-credentials.json:ro
```

### Option B: Custom Path via FCM_CREDENTIALS_PATH

Alternatively, use the `FCM_CREDENTIALS_PATH` environment variable:

```bash
export FCM_CREDENTIALS_PATH="/path/to/serviceAccountKey.json"
```

This is useful if you want to keep FCM credentials separate from other Google Cloud credentials.

## Step 3: Verify Configuration

Start the backend server and check the logs:

```bash
cd server
go run main.go
```

**Expected output (FCM enabled):**
```
FCM client initialized successfully
FCM push notifications enabled
Starting relay server on :8080
```

**Expected output (FCM not configured):**
```
FCM not configured - cast system will use long polling only
To enable FCM push notifications, set GOOGLE_APPLICATION_CREDENTIALS or FCM_CREDENTIALS_PATH environment variable
Starting relay server on :8080
```

**Expected output (FCM configuration error):**
```
Warning: Failed to initialize FCM client: <error details>
Cast system will rely on long polling only
Starting relay server on :8080
```

## Step 4: Configure Mobile/TV Apps

The Flutter apps need to be configured with Firebase as well:

1. Download `google-services.json` (Android) from Firebase Console:
   - Go to Project Settings → General
   - Scroll to "Your apps" section
   - Click on your Android app (or add one if it doesn't exist)
   - Download `google-services.json`

2. Place the file in the Android app directory:
   ```
   oxplayer-android/android/app/google-services.json
   ```

3. Ensure `firebase_messaging` is added to `pubspec.yaml`:
   ```yaml
   dependencies:
     firebase_messaging: ^14.0.0
   ```

4. The app will automatically register for FCM tokens on startup

## Troubleshooting

### "Failed to initialize Firebase app"

**Cause:** Invalid or missing credentials file

**Solution:**
- Verify the file path is correct
- Check file permissions (must be readable by the server process)
- Ensure the JSON file is valid (not corrupted)

### "Failed to send FCM notification"

**Possible causes:**
1. Invalid FCM token (device not registered or token expired)
2. Network connectivity issues
3. Firebase project configuration issues

**Solution:**
- Check server logs for detailed error messages
- Verify the device successfully registered (check `/me/devices/register` endpoint)
- Ensure the Firebase project has Cloud Messaging API enabled

### FCM notifications not received on device

**Possible causes:**
1. App not running or in background
2. Device in Doze mode (Android power saving)
3. FCM token not registered with backend

**Solution:**
- Ensure the app has a foreground service running (for background delivery)
- Check device battery optimization settings
- Verify the device called `/me/devices/register` successfully

## Security Best Practices

1. **Restrict Service Account Permissions:**
   - In Firebase Console → IAM & Admin
   - Ensure the service account only has "Firebase Cloud Messaging Admin" role
   - Remove unnecessary permissions

2. **Rotate Credentials Regularly:**
   - Generate new service account keys every 90 days
   - Delete old keys after rotation

3. **Use Secret Management:**
   - For production, use secret management services (AWS Secrets Manager, HashiCorp Vault, etc.)
   - Avoid storing credentials in plain text files

4. **Monitor Usage:**
   - Enable Firebase Cloud Messaging API monitoring
   - Set up alerts for unusual activity

## Production Deployment Checklist

- [ ] Service account credentials generated
- [ ] Credentials stored securely (not in version control)
- [ ] Environment variable configured in production environment
- [ ] File permissions set correctly (read-only for server process)
- [ ] Firebase Cloud Messaging API enabled in Firebase Console
- [ ] Service account has minimal required permissions
- [ ] Monitoring and alerting configured
- [ ] Backup credentials stored in secure location
- [ ] Credential rotation schedule established

## Cost Considerations

Firebase Cloud Messaging is **free** for unlimited messages. There are no costs associated with FCM usage for this feature.

## Alternative: Long Polling Only

If you prefer not to use FCM, the cast system will work perfectly fine with long polling alone:

- **Latency:** ~15 seconds average (30-second polling interval)
- **Reliability:** Same as FCM (both are reliable)
- **Battery Impact:** Slightly higher (constant HTTP connections)
- **Setup Complexity:** None (works out of the box)

To use long polling only, simply don't configure FCM credentials. The system will automatically fall back to long polling.

## References

- [Firebase Admin SDK Documentation](https://firebase.google.com/docs/admin/setup)
- [Firebase Cloud Messaging Documentation](https://firebase.google.com/docs/cloud-messaging)
- [Service Account Best Practices](https://cloud.google.com/iam/docs/best-practices-service-accounts)
