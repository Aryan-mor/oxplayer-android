package cast

import (
	"context"
	"fmt"
	"log"
	"os"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"google.golang.org/api/option"
)

// FCMClient wraps Firebase Cloud Messaging functionality
type FCMClient struct {
	client *messaging.Client
	ctx    context.Context
}

// NewFCMClient initializes a new FCM client using service account credentials
// The service account JSON file path should be provided via the GOOGLE_APPLICATION_CREDENTIALS
// environment variable, or passed directly via credentialsPath parameter.
//
// Usage:
//   1. Set environment variable: export GOOGLE_APPLICATION_CREDENTIALS="/path/to/serviceAccountKey.json"
//   2. Or pass path directly: NewFCMClient(ctx, "/path/to/serviceAccountKey.json")
//
// To obtain service account credentials:
//   1. Go to Firebase Console: https://console.firebase.google.com/
//   2. Select your project
//   3. Go to Project Settings > Service Accounts
//   4. Click "Generate New Private Key"
//   5. Save the JSON file securely (DO NOT commit to version control)
func NewFCMClient(ctx context.Context, credentialsPath string) (*FCMClient, error) {
	var app *firebase.App
	var err error

	// If credentialsPath is provided, use it directly
	if credentialsPath != "" {
		opt := option.WithCredentialsFile(credentialsPath)
		app, err = firebase.NewApp(ctx, nil, opt)
		if err != nil {
			return nil, fmt.Errorf("failed to initialize Firebase app with credentials file: %w", err)
		}
	} else {
		// Otherwise, try to use GOOGLE_APPLICATION_CREDENTIALS environment variable
		if os.Getenv("GOOGLE_APPLICATION_CREDENTIALS") == "" {
			return nil, fmt.Errorf("FCM credentials not configured: set GOOGLE_APPLICATION_CREDENTIALS environment variable or provide credentialsPath")
		}
		app, err = firebase.NewApp(ctx, nil)
		if err != nil {
			return nil, fmt.Errorf("failed to initialize Firebase app from environment: %w", err)
		}
	}

	// Get messaging client
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get FCM messaging client: %w", err)
	}

	log.Println("FCM client initialized successfully")

	return &FCMClient{
		client: client,
		ctx:    ctx,
	}, nil
}

// SendCastNotification sends a push notification to a device when a cast job is created
func (f *FCMClient) SendCastNotification(fcmToken string, jobID string) error {
	if f.client == nil {
		return fmt.Errorf("FCM client not initialized")
	}

	message := &messaging.Message{
		Token: fcmToken,
		Data: map[string]string{
			"type":  "cast_job",
			"jobId": jobID,
		},
		Android: &messaging.AndroidConfig{
			Priority: "high",
			Notification: &messaging.AndroidNotification{
				Title: "Cast Request",
				Body:  "New media ready to cast",
				Sound: "default",
			},
		},
	}

	response, err := f.client.Send(f.ctx, message)
	if err != nil {
		return fmt.Errorf("failed to send FCM notification: %w", err)
	}

	log.Printf("FCM notification sent successfully: %s", response)
	return nil
}

// SendCastNotificationToDevices sends push notifications to all registered devices for a user
func (f *FCMClient) SendCastNotificationToDevices(devices []*DeviceRegistration, jobID string) {
	if f.client == nil {
		log.Println("FCM client not initialized, skipping push notifications")
		return
	}

	for _, device := range devices {
		go func(dev *DeviceRegistration) {
			if err := f.SendCastNotification(dev.FCMToken, jobID); err != nil {
				log.Printf("Failed to send FCM notification to device %s: %v", dev.DeviceID, err)
			}
		}(device)
	}
}
