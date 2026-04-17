package cast

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/google/uuid"
)

// Handler manages cast-related HTTP endpoints
type Handler struct {
	store       *JobStore
	deviceStore *DeviceStore
	fcmClient   *FCMClient
}

// NewHandler creates a new cast handler
func NewHandler(store *JobStore, deviceStore *DeviceStore) *Handler {
	return &Handler{
		store:       store,
		deviceStore: deviceStore,
		fcmClient:   nil, // FCM client is optional, set via SetFCMClient
	}
}

// SetFCMClient sets the FCM client for push notifications
// This is optional - if not set, the system will rely solely on long polling
func (h *Handler) SetFCMClient(client *FCMClient) {
	h.fcmClient = client
}

// RegisterRoutes registers cast endpoints with the provided mux
func (h *Handler) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/me/cast/jobs", h.handleCreateJob)
	mux.HandleFunc("/me/cast/jobs/claim", h.handleClaimJob)
	mux.HandleFunc("/me/cast/jobs/", h.handleJobStarted)
	mux.HandleFunc("/me/devices/register", h.handleRegisterDevice)
}

// handleCreateJob handles POST /me/cast/jobs
func (h *Handler) handleCreateJob(w http.ResponseWriter, r *http.Request) {
	// Recover from panics and return 500
	defer func() {
		if rec := recover(); rec != nil {
			sendError(w, http.StatusInternalServerError, "Internal server error")
		}
	}()

	// Only accept POST requests
	if r.Method != http.MethodPost {
		sendError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	// Extract userId from request context or header
	// TODO: Replace with actual authentication middleware
	userID := r.Header.Get("X-User-ID")
	if userID == "" {
		sendError(w, http.StatusUnauthorized, "Missing or invalid auth token")
		return
	}

	// Parse request body
	var req CreateCastJobRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		sendError(w, http.StatusBadRequest, "Invalid request payload")
		return
	}

	// Validate required fields
	if req.ChatID == "" {
		sendError(w, http.StatusBadRequest, "chatId is required")
		return
	}
	if req.MessageID == 0 {
		sendError(w, http.StatusBadRequest, "messageId is required")
		return
	}
	if req.FileID == "" {
		sendError(w, http.StatusBadRequest, "fileId is required")
		return
	}
	if req.FileName == "" {
		sendError(w, http.StatusBadRequest, "fileName is required")
		return
	}
	if req.MimeType == "" {
		sendError(w, http.StatusBadRequest, "mimeType is required")
		return
	}
	if req.TotalBytes <= 0 {
		sendError(w, http.StatusBadRequest, "totalBytes must be greater than 0")
		return
	}

	// Generate unique job ID
	jobID := uuid.New().String()
	createdAt := time.Now()

	// Create cast job
	job := &CastJob{
		JobID:        jobID,
		ChatID:       req.ChatID,
		MessageID:    req.MessageID,
		FileID:       req.FileID,
		FileName:     req.FileName,
		MimeType:     req.MimeType,
		TotalBytes:   req.TotalBytes,
		ThumbnailURL: req.ThumbnailURL,
		Metadata:     req.Metadata,
		CreatedAt:    createdAt,
	}

	// Store job in memory keyed by userId
	// Wrap in error handling in case of unexpected failures
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				// If store operation panics, we'll handle it below
				panic(rec)
			}
		}()
		h.store.SetJob(userID, job)
	}()

	// Send FCM push notifications to all registered devices (if FCM is configured)
	if h.fcmClient != nil {
		devices := h.deviceStore.GetDevices(userID)
		if len(devices) > 0 {
			// Send notifications asynchronously (don't block the response)
			go h.fcmClient.SendCastNotificationToDevices(devices, jobID)
		}
	}

	// Return 201 Created with job ID and createdAt
	sendJSON(w, http.StatusCreated, map[string]interface{}{
		"jobId":     jobID,
		"createdAt": createdAt.Format(time.RFC3339),
	})
}

// handleClaimJob handles GET /me/cast/jobs/claim
func (h *Handler) handleClaimJob(w http.ResponseWriter, r *http.Request) {
	// Recover from panics and return 500
	defer func() {
		if rec := recover(); rec != nil {
			sendError(w, http.StatusInternalServerError, "Internal server error")
		}
	}()

	// Only accept GET requests
	if r.Method != http.MethodGet {
		sendError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	// Extract userId from request context or header
	// TODO: Replace with actual authentication middleware
	userID := r.Header.Get("X-User-ID")
	if userID == "" {
		sendError(w, http.StatusUnauthorized, "Missing or invalid auth token")
		return
	}

	// Parse timeout query parameter (default 30s, max 60s)
	timeoutStr := r.URL.Query().Get("timeout")
	timeout := 30 * time.Second // default
	if timeoutStr != "" {
		timeoutSec := 0
		if _, err := fmt.Sscanf(timeoutStr, "%d", &timeoutSec); err == nil {
			if timeoutSec > 60 {
				timeoutSec = 60 // max 60s
			}
			if timeoutSec > 0 {
				timeout = time.Duration(timeoutSec) * time.Second
			}
		}
	}

	// Check if job exists immediately
	job, exists := h.store.ClaimJob(userID)
	if exists {
		// Job exists, return immediately with HTTP 200
		response := ClaimJobResponse{
			JobID:        job.JobID,
			ChatID:       job.ChatID,
			MessageID:    job.MessageID,
			FileID:       job.FileID,
			FileName:     job.FileName,
			MimeType:     job.MimeType,
			TotalBytes:   job.TotalBytes,
			ThumbnailURL: job.ThumbnailURL,
			Metadata:     job.Metadata,
			CreatedAt:    job.CreatedAt,
		}
		sendJSON(w, http.StatusOK, response)
		return
	}

	// No job exists, implement long polling
	ticker := time.NewTicker(100 * time.Millisecond) // Poll every 100ms
	defer ticker.Stop()

	timeoutTimer := time.NewTimer(timeout)
	defer timeoutTimer.Stop()

	for {
		select {
		case <-ticker.C:
			// Check if a job has been created
			job, exists := h.store.ClaimJob(userID)
			if exists {
				// Job created during hold, return immediately with HTTP 200
				response := ClaimJobResponse{
					JobID:        job.JobID,
					ChatID:       job.ChatID,
					MessageID:    job.MessageID,
					FileID:       job.FileID,
					FileName:     job.FileName,
					MimeType:     job.MimeType,
					TotalBytes:   job.TotalBytes,
					ThumbnailURL: job.ThumbnailURL,
					Metadata:     job.Metadata,
					CreatedAt:    job.CreatedAt,
				}
				sendJSON(w, http.StatusOK, response)
				return
			}
		case <-timeoutTimer.C:
			// Timeout expired, return HTTP 204
			w.WriteHeader(http.StatusNoContent)
			return
		case <-r.Context().Done():
			// Client disconnected, stop polling
			return
		}
	}
}

// sendJSON sends a JSON response
func sendJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		// If JSON encoding fails, we can't change the status code (already written)
		// Log the error for debugging
		// In production, this would use a proper logger
		return
	}
}

// sendError sends an error response
func sendError(w http.ResponseWriter, status int, message string) {
	sendJSON(w, status, map[string]string{"error": message})
}

// handleJobStarted handles POST /me/cast/jobs/:id/started
func (h *Handler) handleJobStarted(w http.ResponseWriter, r *http.Request) {
	// Recover from panics and return 500
	defer func() {
		if rec := recover(); rec != nil {
			sendError(w, http.StatusInternalServerError, "Internal server error")
		}
	}()

	// Only accept POST requests
	if r.Method != http.MethodPost {
		sendError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	// Extract userId from request context or header
	// TODO: Replace with actual authentication middleware
	userID := r.Header.Get("X-User-ID")
	if userID == "" {
		sendError(w, http.StatusUnauthorized, "Missing or invalid auth token")
		return
	}

	// Parse job ID from URL path
	// URL format: /me/cast/jobs/:id/started
	// Extract the job ID from the path
	path := r.URL.Path
	// Remove trailing "/started"
	if len(path) < 8 || path[len(path)-8:] != "/started" {
		sendError(w, http.StatusBadRequest, "Invalid URL format")
		return
	}
	
	// Extract job ID: remove "/me/cast/jobs/" prefix and "/started" suffix
	prefix := "/me/cast/jobs/"
	if len(path) <= len(prefix)+8 {
		sendError(w, http.StatusBadRequest, "Missing job ID")
		return
	}
	
	jobID := path[len(prefix) : len(path)-8]
	if jobID == "" {
		sendError(w, http.StatusBadRequest, "Missing job ID")
		return
	}

	// Remove job from memory (idempotent - no error if job doesn't exist)
	// We don't need to verify if the job exists or if it belongs to this user
	// The endpoint is idempotent and always returns 200
	h.store.RemoveJob(userID)

	// Return HTTP 200 with acknowledgment response
	sendJSON(w, http.StatusOK, map[string]bool{
		"acknowledged": true,
	})
}

// handleRegisterDevice handles POST /me/devices/register
func (h *Handler) handleRegisterDevice(w http.ResponseWriter, r *http.Request) {
	// Recover from panics and return 500
	defer func() {
		if rec := recover(); rec != nil {
			sendError(w, http.StatusInternalServerError, "Internal server error")
		}
	}()

	// Only accept POST requests
	if r.Method != http.MethodPost {
		sendError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	// Extract userId from request context or header
	// TODO: Replace with actual authentication middleware
	userID := r.Header.Get("X-User-ID")
	if userID == "" {
		sendError(w, http.StatusUnauthorized, "Missing or invalid auth token")
		return
	}

	// Parse request body
	var req RegisterDeviceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		sendError(w, http.StatusBadRequest, "Invalid request payload")
		return
	}

	// Validate required fields
	if req.DeviceID == "" {
		sendError(w, http.StatusBadRequest, "deviceId is required")
		return
	}
	if req.FCMToken == "" {
		sendError(w, http.StatusBadRequest, "fcmToken is required")
		return
	}
	if req.Platform == "" {
		sendError(w, http.StatusBadRequest, "platform is required")
		return
	}
	if req.AppVersion == "" {
		sendError(w, http.StatusBadRequest, "appVersion is required")
		return
	}

	// Create device registration
	device := &DeviceRegistration{
		DeviceID:   req.DeviceID,
		FCMToken:   req.FCMToken,
		Platform:   req.Platform,
		AppVersion: req.AppVersion,
		UserID:     userID,
	}

	// Store device registration in memory
	// In production, this would be stored in a database
	h.deviceStore.RegisterDevice(userID, device)

	// Return HTTP 200 with registration confirmation
	sendJSON(w, http.StatusOK, map[string]bool{
		"registered": true,
	})
}
