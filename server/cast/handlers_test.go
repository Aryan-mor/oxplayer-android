package cast

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestHandleCreateJob_Success(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}

	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)

	if response["jobId"] == nil {
		t.Error("Expected jobId in response")
	}

	if response["createdAt"] == nil {
		t.Error("Expected createdAt in response")
	}

	// Verify job was stored
	job, exists := store.GetJob("user123")
	if !exists {
		t.Error("Expected job to be stored")
	}

	if job.ChatID != payload.ChatID {
		t.Errorf("Expected chatId %s, got %s", payload.ChatID, job.ChatID)
	}

	if job.MessageID != payload.MessageID {
		t.Errorf("Expected messageId %d, got %d", payload.MessageID, job.MessageID)
	}

	if job.FileID != payload.FileID {
		t.Errorf("Expected fileId %s, got %s", payload.FileID, job.FileID)
	}

	if job.FileName != payload.FileName {
		t.Errorf("Expected fileName %s, got %s", payload.FileName, job.FileName)
	}

	if job.MimeType != payload.MimeType {
		t.Errorf("Expected mimeType %s, got %s", payload.MimeType, job.MimeType)
	}

	if job.TotalBytes != payload.TotalBytes {
		t.Errorf("Expected totalBytes %d, got %d", payload.TotalBytes, job.TotalBytes)
	}
}

func TestHandleCreateJob_WithOptionalFields(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	thumbnailURL := "https://example.com/thumb.jpg"
	metadata := map[string]interface{}{
		"title":    "My Video",
		"duration": 120,
	}

	payload := CreateCastJobRequest{
		ChatID:       "chat123",
		MessageID:    456,
		FileID:       "file789",
		FileName:     "video.mp4",
		MimeType:     "video/mp4",
		TotalBytes:   1024000,
		ThumbnailURL: &thumbnailURL,
		Metadata:     metadata,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}

	// Verify optional fields were stored
	job, exists := store.GetJob("user123")
	if !exists {
		t.Error("Expected job to be stored")
	}

	if job.ThumbnailURL == nil || *job.ThumbnailURL != thumbnailURL {
		t.Errorf("Expected thumbnailUrl %s, got %v", thumbnailURL, job.ThumbnailURL)
	}

	if job.Metadata == nil {
		t.Error("Expected metadata to be stored")
	}

	if job.Metadata["title"] != "My Video" {
		t.Errorf("Expected metadata title 'My Video', got %v", job.Metadata["title"])
	}
}

func TestHandleCreateJob_MethodNotAllowed(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Expected status 405, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Method not allowed" {
		t.Errorf("Expected error message 'Method not allowed', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingAuth(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	// No X-User-ID header

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status 401, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Missing or invalid auth token" {
		t.Errorf("Expected error message 'Missing or invalid auth token', got %s", response["error"])
	}
}

func TestHandleCreateJob_InvalidJSON(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader([]byte("invalid json")))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Invalid request payload" {
		t.Errorf("Expected error message 'Invalid request payload', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingChatID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		// ChatID missing
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "chatId is required" {
		t.Errorf("Expected error message 'chatId is required', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingMessageID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID: "chat123",
		// MessageID missing (0)
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "messageId is required" {
		t.Errorf("Expected error message 'messageId is required', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingFileID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:    "chat123",
		MessageID: 456,
		// FileID missing
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "fileId is required" {
		t.Errorf("Expected error message 'fileId is required', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingFileName(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:    "chat123",
		MessageID: 456,
		FileID:    "file789",
		// FileName missing
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "fileName is required" {
		t.Errorf("Expected error message 'fileName is required', got %s", response["error"])
	}
}

func TestHandleCreateJob_MissingMimeType(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:    "chat123",
		MessageID: 456,
		FileID:    "file789",
		FileName:  "video.mp4",
		// MimeType missing
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "mimeType is required" {
		t.Errorf("Expected error message 'mimeType is required', got %s", response["error"])
	}
}

func TestHandleCreateJob_InvalidTotalBytes(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:    "chat123",
		MessageID: 456,
		FileID:    "file789",
		FileName:  "video.mp4",
		MimeType:  "video/mp4",
		TotalBytes: 0, // Invalid: must be > 0
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "totalBytes must be greater than 0" {
		t.Errorf("Expected error message 'totalBytes must be greater than 0', got %s", response["error"])
	}
}

func TestHandleCreateJob_JobIDIsUUID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)

	jobID, ok := response["jobId"].(string)
	if !ok {
		t.Error("Expected jobId to be a string")
	}

	// UUID format: 8-4-4-4-12 characters
	if len(jobID) != 36 {
		t.Errorf("Expected UUID length 36, got %d", len(jobID))
	}
}

func TestHandleCreateJob_CreatedAtIsRFC3339(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)

	createdAt, ok := response["createdAt"].(string)
	if !ok {
		t.Error("Expected createdAt to be a string")
	}

	// Verify it's a valid RFC3339 timestamp
	_, err := time.Parse(time.RFC3339, createdAt)
	if err != nil {
		t.Errorf("Expected createdAt to be RFC3339 format, got error: %v", err)
	}
}

func TestHandleCreateJob_OverwritesPreviousJob(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// Create first job
	payload1 := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video1.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body1, _ := json.Marshal(payload1)
	req1 := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body1))
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleCreateJob(w1, req1)

	// Create second job for same user
	payload2 := CreateCastJobRequest{
		ChatID:     "chat456",
		MessageID:  789,
		FileID:     "file012",
		FileName:   "video2.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 2048000,
	}

	body2, _ := json.Marshal(payload2)
	req2 := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body2))
	req2.Header.Set("X-User-ID", "user123")

	w2 := httptest.NewRecorder()
	handler.handleCreateJob(w2, req2)

	// Verify second job overwrote first
	job, exists := store.GetJob("user123")
	if !exists {
		t.Error("Expected job to be stored")
	}

	if job.FileName != "video2.mp4" {
		t.Errorf("Expected fileName 'video2.mp4', got %s", job.FileName)
	}

	if job.ChatID != "chat456" {
		t.Errorf("Expected chatId 'chat456', got %s", job.ChatID)
	}
}

func TestHandleCreateJob_ServerError(t *testing.T) {
	// Create a nil store to trigger a panic/error
	handler := &Handler{
		store: nil,
	}

	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Internal server error" {
		t.Errorf("Expected error message 'Internal server error', got %s", response["error"])
	}
}

// Tests for handleClaimJob

func TestHandleClaimJob_ImmediateJobAvailable(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job first
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Claim the job
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response ClaimJobResponse
	json.NewDecoder(w.Body).Decode(&response)

	if response.JobID != job.JobID {
		t.Errorf("Expected jobId %s, got %s", job.JobID, response.JobID)
	}

	if response.ChatID != job.ChatID {
		t.Errorf("Expected chatId %s, got %s", job.ChatID, response.ChatID)
	}

	if response.MessageID != job.MessageID {
		t.Errorf("Expected messageId %d, got %d", job.MessageID, response.MessageID)
	}

	if response.FileID != job.FileID {
		t.Errorf("Expected fileId %s, got %s", job.FileID, response.FileID)
	}

	if response.FileName != job.FileName {
		t.Errorf("Expected fileName %s, got %s", job.FileName, response.FileName)
	}

	if response.MimeType != job.MimeType {
		t.Errorf("Expected mimeType %s, got %s", job.MimeType, response.MimeType)
	}

	if response.TotalBytes != job.TotalBytes {
		t.Errorf("Expected totalBytes %d, got %d", job.TotalBytes, response.TotalBytes)
	}

	// Verify job was removed from store (atomic claim)
	_, exists := store.GetJob("user123")
	if exists {
		t.Error("Expected job to be removed after claim")
	}
}

func TestHandleClaimJob_NoJobTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// No job exists, should timeout
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=1", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	start := time.Now()
	handler.handleClaimJob(w, req)
	elapsed := time.Since(start)

	if w.Code != http.StatusNoContent {
		t.Errorf("Expected status 204, got %d", w.Code)
	}

	// Verify timeout was respected (should be around 1 second)
	if elapsed < 900*time.Millisecond || elapsed > 1500*time.Millisecond {
		t.Errorf("Expected timeout around 1s, got %v", elapsed)
	}
}

func TestHandleClaimJob_DefaultTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// No job exists, should use default 30s timeout
	// We'll cancel early to avoid waiting 30s
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	req.Header.Set("X-User-ID", "user123")

	// Create a context that cancels after 500ms
	ctx, cancel := context.WithTimeout(req.Context(), 500*time.Millisecond)
	defer cancel()
	req = req.WithContext(ctx)

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	// Should return nothing (client disconnected)
	// The handler should exit gracefully when context is cancelled
}

func TestHandleClaimJob_MaxTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Request timeout > 60s, should be capped at 60s
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=120", nil)
	req.Header.Set("X-User-ID", "user123")

	// Cancel early to avoid waiting 60s
	ctx, cancel := context.WithTimeout(req.Context(), 500*time.Millisecond)
	defer cancel()
	req = req.WithContext(ctx)

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	// Should exit gracefully when context is cancelled
}

func TestHandleClaimJob_JobCreatedDuringWait(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Start claim request in goroutine
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=5", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()

	done := make(chan bool)
	go func() {
		handler.handleClaimJob(w, req)
		done <- true
	}()

	// Wait 500ms, then create a job
	time.Sleep(500 * time.Millisecond)
	job := &CastJob{
		JobID:      "job456",
		ChatID:     "chat456",
		MessageID:  789,
		FileID:     "file012",
		FileName:   "audio.mp3",
		MimeType:   "audio/mp3",
		TotalBytes: 512000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Wait for handler to complete
	<-done

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response ClaimJobResponse
	json.NewDecoder(w.Body).Decode(&response)

	if response.JobID != job.JobID {
		t.Errorf("Expected jobId %s, got %s", job.JobID, response.JobID)
	}

	// Verify job was removed from store
	_, exists := store.GetJob("user123")
	if exists {
		t.Error("Expected job to be removed after claim")
	}
}

func TestHandleClaimJob_MethodNotAllowed(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/claim", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Expected status 405, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Method not allowed" {
		t.Errorf("Expected error message 'Method not allowed', got %s", response["error"])
	}
}

func TestHandleClaimJob_MissingAuth(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	// No X-User-ID header

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status 401, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Missing or invalid auth token" {
		t.Errorf("Expected error message 'Missing or invalid auth token', got %s", response["error"])
	}
}

func TestHandleClaimJob_WithOptionalFields(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	thumbnailURL := "https://example.com/thumb.jpg"
	metadata := map[string]interface{}{
		"title":    "My Video",
		"duration": 120,
	}

	// Create a job with optional fields
	job := &CastJob{
		JobID:        "job123",
		ChatID:       "chat123",
		MessageID:    456,
		FileID:       "file789",
		FileName:     "video.mp4",
		MimeType:     "video/mp4",
		TotalBytes:   1024000,
		ThumbnailURL: &thumbnailURL,
		Metadata:     metadata,
		CreatedAt:    time.Now(),
	}
	store.SetJob("user123", job)

	// Claim the job
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response ClaimJobResponse
	json.NewDecoder(w.Body).Decode(&response)

	if response.ThumbnailURL == nil || *response.ThumbnailURL != thumbnailURL {
		t.Errorf("Expected thumbnailUrl %s, got %v", thumbnailURL, response.ThumbnailURL)
	}

	if response.Metadata == nil {
		t.Error("Expected metadata to be present")
	}

	if response.Metadata["title"] != "My Video" {
		t.Errorf("Expected metadata title 'My Video', got %v", response.Metadata["title"])
	}
}

func TestHandleClaimJob_AtomicClaim(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// First claim should succeed
	req1 := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleClaimJob(w1, req1)

	if w1.Code != http.StatusOK {
		t.Errorf("Expected first claim status 200, got %d", w1.Code)
	}

	// Second claim should timeout (job already claimed)
	req2 := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=1", nil)
	req2.Header.Set("X-User-ID", "user123")

	w2 := httptest.NewRecorder()
	handler.handleClaimJob(w2, req2)

	if w2.Code != http.StatusNoContent {
		t.Errorf("Expected second claim status 204, got %d", w2.Code)
	}
}

func TestHandleClaimJob_InvalidTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Invalid timeout should use default
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=invalid", nil)
	req.Header.Set("X-User-ID", "user123")

	// Cancel early to avoid waiting
	ctx, cancel := context.WithTimeout(req.Context(), 500*time.Millisecond)
	defer cancel()
	req = req.WithContext(ctx)

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	// Should exit gracefully when context is cancelled
}

func TestHandleClaimJob_ZeroTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Zero timeout should use default
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=0", nil)
	req.Header.Set("X-User-ID", "user123")

	// Cancel early to avoid waiting
	ctx, cancel := context.WithTimeout(req.Context(), 500*time.Millisecond)
	defer cancel()
	req = req.WithContext(ctx)

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	// Should exit gracefully when context is cancelled
}

func TestHandleClaimJob_NegativeTimeout(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Negative timeout should use default
	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim?timeout=-5", nil)
	req.Header.Set("X-User-ID", "user123")

	// Cancel early to avoid waiting
	ctx, cancel := context.WithTimeout(req.Context(), 500*time.Millisecond)
	defer cancel()
	req = req.WithContext(ctx)

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	// Should exit gracefully when context is cancelled
}

func TestHandleClaimJob_ServerError(t *testing.T) {
	// Create a nil store to trigger a panic/error
	handler := &Handler{
		store: nil,
	}

	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/claim", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleClaimJob(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Internal server error" {
		t.Errorf("Expected error message 'Internal server error', got %s", response["error"])
	}
}

// Tests for handleJobStarted

func TestHandleJobStarted_Success(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job first
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Acknowledge the job
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}

	// Verify job was removed from store
	_, exists := store.GetJob("user123")
	if exists {
		t.Error("Expected job to be removed after acknowledgment")
	}
}

func TestHandleJobStarted_IdempotentNoJob(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// No job exists, but should still return 200 (idempotent)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}
}

func TestHandleJobStarted_IdempotentAlreadyRemoved(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create and remove a job
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)
	store.RemoveJob("user123")

	// Acknowledge again - should still return 200
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}
}

func TestHandleJobStarted_MethodNotAllowed(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	req := httptest.NewRequest(http.MethodGet, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Expected status 405, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Method not allowed" {
		t.Errorf("Expected error message 'Method not allowed', got %s", response["error"])
	}
}

func TestHandleJobStarted_MissingAuth(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	// No X-User-ID header

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status 401, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Missing or invalid auth token" {
		t.Errorf("Expected error message 'Missing or invalid auth token', got %s", response["error"])
	}
}

func TestHandleJobStarted_MissingJobID(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// URL without job ID
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs//started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Missing job ID" {
		t.Errorf("Expected error message 'Missing job ID', got %s", response["error"])
	}
}

func TestHandleJobStarted_InvalidURLFormat(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// URL without /started suffix
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Invalid URL format" {
		t.Errorf("Expected error message 'Invalid URL format', got %s", response["error"])
	}
}

func TestHandleJobStarted_DifferentJobIDs(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Acknowledge with a different job ID (should still return 200 - idempotent)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job456/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}

	// Job should still be removed (we remove by userID, not jobID)
	_, exists := store.GetJob("user123")
	if exists {
		t.Error("Expected job to be removed after acknowledgment")
	}
}

func TestHandleJobStarted_MultipleUsers(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create jobs for two users
	job1 := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video1.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job1)

	job2 := &CastJob{
		JobID:      "job456",
		ChatID:     "chat456",
		MessageID:  789,
		FileID:     "file012",
		FileName:   "video2.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 2048000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user456", job2)

	// User1 acknowledges their job
	req1 := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleJobStarted(w1, req1)

	if w1.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w1.Code)
	}

	// User1's job should be removed
	_, exists1 := store.GetJob("user123")
	if exists1 {
		t.Error("Expected user123's job to be removed")
	}

	// User2's job should still exist
	_, exists2 := store.GetJob("user456")
	if !exists2 {
		t.Error("Expected user456's job to still exist")
	}
}

func TestHandleJobStarted_ServerError(t *testing.T) {
	// Create a nil store to trigger a panic/error
	handler := &Handler{
		store: nil,
	}

	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Internal server error" {
		t.Errorf("Expected error message 'Internal server error', got %s", response["error"])
	}
}

func TestHandleJobStarted_UUIDJobID(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job with UUID
	job := &CastJob{
		JobID:      "550e8400-e29b-41d4-a716-446655440000",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Acknowledge with UUID job ID
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/550e8400-e29b-41d4-a716-446655440000/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}

	// Verify job was removed
	_, exists := store.GetJob("user123")
	if exists {
		t.Error("Expected job to be removed after acknowledgment")
	}
}

func TestHandleJobStarted_EmptyBody(t *testing.T) {
	store := NewJobStore()
	handler := NewHandler(store)

	// Create a job
	job := &CastJob{
		JobID:      "job123",
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}
	store.SetJob("user123", job)

	// Acknowledge with empty body (as per spec)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs/job123/started", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleJobStarted(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["acknowledged"] {
		t.Error("Expected acknowledged to be true")
	}
}

// Tests for handleRegisterDevice

func TestHandleRegisterDevice_Success(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	var response map[string]bool
	json.NewDecoder(w.Body).Decode(&response)

	if !response["registered"] {
		t.Error("Expected registered to be true")
	}

	// Verify device was stored
	device, exists := deviceStore.GetDevice("user123", "device123")
	if !exists {
		t.Error("Expected device to be stored")
	}

	if device.DeviceID != payload.DeviceID {
		t.Errorf("Expected deviceId %s, got %s", payload.DeviceID, device.DeviceID)
	}

	if device.FCMToken != payload.FCMToken {
		t.Errorf("Expected fcmToken %s, got %s", payload.FCMToken, device.FCMToken)
	}

	if device.Platform != payload.Platform {
		t.Errorf("Expected platform %s, got %s", payload.Platform, device.Platform)
	}

	if device.AppVersion != payload.AppVersion {
		t.Errorf("Expected appVersion %s, got %s", payload.AppVersion, device.AppVersion)
	}

	if device.UserID != "user123" {
		t.Errorf("Expected userId user123, got %s", device.UserID)
	}
}

func TestHandleRegisterDevice_UpdateExistingDevice(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// Register device first time
	payload1 := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_old",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body1, _ := json.Marshal(payload1)
	req1 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body1))
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleRegisterDevice(w1, req1)

	// Register same device with new token (token refresh)
	payload2 := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_new",
		Platform:   "android",
		AppVersion: "1.0.1",
	}

	body2, _ := json.Marshal(payload2)
	req2 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body2))
	req2.Header.Set("X-User-ID", "user123")

	w2 := httptest.NewRecorder()
	handler.handleRegisterDevice(w2, req2)

	if w2.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w2.Code)
	}

	// Verify device was updated with new token
	device, exists := deviceStore.GetDevice("user123", "device123")
	if !exists {
		t.Error("Expected device to be stored")
	}

	if device.FCMToken != "fcm_token_new" {
		t.Errorf("Expected updated fcmToken fcm_token_new, got %s", device.FCMToken)
	}

	if device.AppVersion != "1.0.1" {
		t.Errorf("Expected updated appVersion 1.0.1, got %s", device.AppVersion)
	}
}

func TestHandleRegisterDevice_MultipleDevicesPerUser(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// Register first device
	payload1 := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_device1",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body1, _ := json.Marshal(payload1)
	req1 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body1))
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleRegisterDevice(w1, req1)

	// Register second device for same user
	payload2 := RegisterDeviceRequest{
		DeviceID:   "device456",
		FCMToken:   "fcm_token_device2",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body2, _ := json.Marshal(payload2)
	req2 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body2))
	req2.Header.Set("X-User-ID", "user123")

	w2 := httptest.NewRecorder()
	handler.handleRegisterDevice(w2, req2)

	// Verify both devices are stored
	devices := deviceStore.GetDevices("user123")
	if len(devices) != 2 {
		t.Errorf("Expected 2 devices, got %d", len(devices))
	}

	// Verify both devices exist
	device1, exists1 := deviceStore.GetDevice("user123", "device123")
	if !exists1 {
		t.Error("Expected device123 to be stored")
	}

	device2, exists2 := deviceStore.GetDevice("user123", "device456")
	if !exists2 {
		t.Error("Expected device456 to be stored")
	}

	if device1.FCMToken != "fcm_token_device1" {
		t.Errorf("Expected device1 token fcm_token_device1, got %s", device1.FCMToken)
	}

	if device2.FCMToken != "fcm_token_device2" {
		t.Errorf("Expected device2 token fcm_token_device2, got %s", device2.FCMToken)
	}
}

func TestHandleRegisterDevice_DifferentUsers(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// Register device for user1
	payload1 := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_user1",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body1, _ := json.Marshal(payload1)
	req1 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body1))
	req1.Header.Set("X-User-ID", "user123")

	w1 := httptest.NewRecorder()
	handler.handleRegisterDevice(w1, req1)

	// Register device for user2
	payload2 := RegisterDeviceRequest{
		DeviceID:   "device456",
		FCMToken:   "fcm_token_user2",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body2, _ := json.Marshal(payload2)
	req2 := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body2))
	req2.Header.Set("X-User-ID", "user456")

	w2 := httptest.NewRecorder()
	handler.handleRegisterDevice(w2, req2)

	// Verify devices are stored separately per user
	devices1 := deviceStore.GetDevices("user123")
	if len(devices1) != 1 {
		t.Errorf("Expected 1 device for user123, got %d", len(devices1))
	}

	devices2 := deviceStore.GetDevices("user456")
	if len(devices2) != 1 {
		t.Errorf("Expected 1 device for user456, got %d", len(devices2))
	}

	device1, _ := deviceStore.GetDevice("user123", "device123")
	device2, _ := deviceStore.GetDevice("user456", "device456")

	if device1.FCMToken != "fcm_token_user1" {
		t.Errorf("Expected user1 token fcm_token_user1, got %s", device1.FCMToken)
	}

	if device2.FCMToken != "fcm_token_user2" {
		t.Errorf("Expected user2 token fcm_token_user2, got %s", device2.FCMToken)
	}
}

func TestHandleRegisterDevice_MethodNotAllowed(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	req := httptest.NewRequest(http.MethodGet, "/me/devices/register", nil)
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("Expected status 405, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Method not allowed" {
		t.Errorf("Expected error message 'Method not allowed', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_MissingAuth(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	// No X-User-ID header

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("Expected status 401, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Missing or invalid auth token" {
		t.Errorf("Expected error message 'Missing or invalid auth token', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_InvalidJSON(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader([]byte("invalid json")))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Invalid request payload" {
		t.Errorf("Expected error message 'Invalid request payload', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_MissingDeviceID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		// DeviceID missing
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "deviceId is required" {
		t.Errorf("Expected error message 'deviceId is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_MissingFCMToken(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID: "device123",
		// FCMToken missing
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "fcmToken is required" {
		t.Errorf("Expected error message 'fcmToken is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_MissingPlatform(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID: "device123",
		FCMToken: "fcm_token_abc123",
		// Platform missing
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "platform is required" {
		t.Errorf("Expected error message 'platform is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_MissingAppVersion(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID: "device123",
		FCMToken: "fcm_token_abc123",
		Platform: "android",
		// AppVersion missing
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "appVersion is required" {
		t.Errorf("Expected error message 'appVersion is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_EmptyDeviceID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "", // Empty string
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "deviceId is required" {
		t.Errorf("Expected error message 'deviceId is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_EmptyFCMToken(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "", // Empty string
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "fcmToken is required" {
		t.Errorf("Expected error message 'fcmToken is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_EmptyPlatform(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "", // Empty string
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "platform is required" {
		t.Errorf("Expected error message 'platform is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_EmptyAppVersion(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "", // Empty string
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("Expected status 400, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "appVersion is required" {
		t.Errorf("Expected error message 'appVersion is required', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_ServerError(t *testing.T) {
	// Create a nil deviceStore to trigger a panic/error
	handler := &Handler{
		store:       NewJobStore(),
		deviceStore: nil,
	}

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("Expected status 500, got %d", w.Code)
	}

	var response map[string]string
	json.NewDecoder(w.Body).Decode(&response)

	if response["error"] != "Internal server error" {
		t.Errorf("Expected error message 'Internal server error', got %s", response["error"])
	}
}

func TestHandleRegisterDevice_LongFCMToken(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// FCM tokens can be quite long (152+ characters)
	longToken := "dQw4w9WgXcQ:APA91bHun4MxP5egoKMwt2KZFBaFUH-1RYqx1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890abcdefghijklmnopqrstuvwxyz"

	payload := RegisterDeviceRequest{
		DeviceID:   "device123",
		FCMToken:   longToken,
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// Verify long token was stored correctly
	device, exists := deviceStore.GetDevice("user123", "device123")
	if !exists {
		t.Error("Expected device to be stored")
	}

	if device.FCMToken != longToken {
		t.Error("Expected long FCM token to be stored correctly")
	}
}

func TestHandleRegisterDevice_SpecialCharactersInDeviceID(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	// Device IDs can contain special characters
	deviceID := "device-123_abc.xyz"

	payload := RegisterDeviceRequest{
		DeviceID:   deviceID,
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
	}

	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")

	w := httptest.NewRecorder()
	handler.handleRegisterDevice(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("Expected status 200, got %d", w.Code)
	}

	// Verify device with special characters was stored
	device, exists := deviceStore.GetDevice("user123", deviceID)
	if !exists {
		t.Error("Expected device to be stored")
	}

	if device.DeviceID != deviceID {
		t.Errorf("Expected deviceId %s, got %s", deviceID, device.DeviceID)
	}
}

func TestHandleRegisterDevice_DifferentPlatforms(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)

	platforms := []string{"android", "ios", "web", "desktop"}

	for i, platform := range platforms {
		payload := RegisterDeviceRequest{
			DeviceID:   "device" + string(rune('0'+i)),
			FCMToken:   "fcm_token_" + platform,
			Platform:   platform,
			AppVersion: "1.0.0",
		}

		body, _ := json.Marshal(payload)
		req := httptest.NewRequest(http.MethodPost, "/me/devices/register", bytes.NewReader(body))
		req.Header.Set("X-User-ID", "user123")

		w := httptest.NewRecorder()
		handler.handleRegisterDevice(w, req)

		if w.Code != http.StatusOK {
			t.Errorf("Expected status 200 for platform %s, got %d", platform, w.Code)
		}
	}

	// Verify all platforms were stored
	devices := deviceStore.GetDevices("user123")
	if len(devices) != len(platforms) {
		t.Errorf("Expected %d devices, got %d", len(platforms), len(devices))
	}
}

// Tests for FCM integration

// MockFCMClient is a mock implementation of FCM client for testing
type MockFCMClient struct {
	sendCalled           bool
	lastJobID            string
	lastDevices          []*DeviceRegistration
	shouldFail           bool
	sendCallCount        int
	deviceCallCounts     map[string]int
}

func NewMockFCMClient() *MockFCMClient {
	return &MockFCMClient{
		deviceCallCounts: make(map[string]int),
	}
}

func (m *MockFCMClient) SendCastNotification(fcmToken string, jobID string) error {
	m.sendCalled = true
	m.lastJobID = jobID
	m.sendCallCount++
	m.deviceCallCounts[fcmToken]++
	
	if m.shouldFail {
		return fmt.Errorf("mock FCM error")
	}
	return nil
}

func (m *MockFCMClient) SendCastNotificationToDevices(devices []*DeviceRegistration, jobID string) {
	m.lastDevices = devices
	m.lastJobID = jobID
	
	for _, device := range devices {
		go func(dev *DeviceRegistration) {
			_ = m.SendCastNotification(dev.FCMToken, jobID)
		}(device)
	}
}

func TestHandleCreateJob_SendsFCMNotification(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Create mock FCM client
	mockFCM := NewMockFCMClient()
	handler.SetFCMClient(mockFCM)
	
	// Register a device first
	device := &DeviceRegistration{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	deviceStore.RegisterDevice("user123", device)
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}
	
	// Give goroutine time to execute
	time.Sleep(100 * time.Millisecond)
	
	// Verify FCM notification was sent
	if !mockFCM.sendCalled {
		t.Error("Expected FCM notification to be sent")
	}
	
	if len(mockFCM.lastDevices) != 1 {
		t.Errorf("Expected 1 device, got %d", len(mockFCM.lastDevices))
	}
	
	if mockFCM.lastDevices[0].FCMToken != "fcm_token_abc123" {
		t.Errorf("Expected FCM token fcm_token_abc123, got %s", mockFCM.lastDevices[0].FCMToken)
	}
}

func TestHandleCreateJob_SendsFCMToMultipleDevices(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Create mock FCM client
	mockFCM := NewMockFCMClient()
	handler.SetFCMClient(mockFCM)
	
	// Register multiple devices
	device1 := &DeviceRegistration{
		DeviceID:   "device1",
		FCMToken:   "fcm_token_1",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	device2 := &DeviceRegistration{
		DeviceID:   "device2",
		FCMToken:   "fcm_token_2",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	deviceStore.RegisterDevice("user123", device1)
	deviceStore.RegisterDevice("user123", device2)
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}
	
	// Give goroutines time to execute
	time.Sleep(100 * time.Millisecond)
	
	// Verify FCM notifications were sent to both devices
	if len(mockFCM.lastDevices) != 2 {
		t.Errorf("Expected 2 devices, got %d", len(mockFCM.lastDevices))
	}
	
	// Verify both tokens were called
	if mockFCM.deviceCallCounts["fcm_token_1"] != 1 {
		t.Errorf("Expected fcm_token_1 to be called once, got %d", mockFCM.deviceCallCounts["fcm_token_1"])
	}
	
	if mockFCM.deviceCallCounts["fcm_token_2"] != 1 {
		t.Errorf("Expected fcm_token_2 to be called once, got %d", mockFCM.deviceCallCounts["fcm_token_2"])
	}
}

func TestHandleCreateJob_NoFCMWhenNoDevices(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Create mock FCM client
	mockFCM := NewMockFCMClient()
	handler.SetFCMClient(mockFCM)
	
	// Don't register any devices
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}
	
	// Give goroutine time to execute (if any)
	time.Sleep(100 * time.Millisecond)
	
	// Verify no FCM notification was sent
	if mockFCM.sendCalled {
		t.Error("Expected no FCM notification to be sent when no devices registered")
	}
}

func TestHandleCreateJob_FCMErrorDoesNotFailRequest(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Create mock FCM client that fails
	mockFCM := NewMockFCMClient()
	mockFCM.shouldFail = true
	handler.SetFCMClient(mockFCM)
	
	// Register a device
	device := &DeviceRegistration{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	deviceStore.RegisterDevice("user123", device)
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	// Request should still succeed even if FCM fails
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201 even with FCM error, got %d", w.Code)
	}
	
	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)
	
	if response["jobId"] == nil {
		t.Error("Expected jobId in response even with FCM error")
	}
	
	// Verify job was still stored
	job, exists := store.GetJob("user123")
	if !exists {
		t.Error("Expected job to be stored even with FCM error")
	}
	
	if job.FileID != payload.FileID {
		t.Error("Expected job to be stored correctly even with FCM error")
	}
}

func TestHandleCreateJob_NoFCMClientConfigured(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Don't set FCM client (simulates FCM not configured)
	
	// Register a device
	device := &DeviceRegistration{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	deviceStore.RegisterDevice("user123", device)
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	// Request should succeed even without FCM client
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201 without FCM client, got %d", w.Code)
	}
	
	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)
	
	if response["jobId"] == nil {
		t.Error("Expected jobId in response without FCM client")
	}
	
	// Verify job was stored
	job, exists := store.GetJob("user123")
	if !exists {
		t.Error("Expected job to be stored without FCM client")
	}
}

func TestHandleCreateJob_FCMIncludesJobMetadata(t *testing.T) {
	store := NewJobStore()
	deviceStore := NewDeviceStore()
	handler := NewHandler(store, deviceStore)
	
	// Create mock FCM client
	mockFCM := NewMockFCMClient()
	handler.SetFCMClient(mockFCM)
	
	// Register a device
	device := &DeviceRegistration{
		DeviceID:   "device123",
		FCMToken:   "fcm_token_abc123",
		Platform:   "android",
		AppVersion: "1.0.0",
		UserID:     "user123",
	}
	deviceStore.RegisterDevice("user123", device)
	
	// Create cast job
	payload := CreateCastJobRequest{
		ChatID:     "chat123",
		MessageID:  456,
		FileID:     "file789",
		FileName:   "video.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
	}
	
	body, _ := json.Marshal(payload)
	req := httptest.NewRequest(http.MethodPost, "/me/cast/jobs", bytes.NewReader(body))
	req.Header.Set("X-User-ID", "user123")
	req.Header.Set("Content-Type", "application/json")
	
	w := httptest.NewRecorder()
	handler.handleCreateJob(w, req)
	
	if w.Code != http.StatusCreated {
		t.Errorf("Expected status 201, got %d", w.Code)
	}
	
	// Parse response to get job ID
	var response map[string]interface{}
	json.NewDecoder(w.Body).Decode(&response)
	jobID := response["jobId"].(string)
	
	// Give goroutine time to execute
	time.Sleep(100 * time.Millisecond)
	
	// Verify FCM notification includes job ID
	if mockFCM.lastJobID != jobID {
		t.Errorf("Expected FCM notification to include jobId %s, got %s", jobID, mockFCM.lastJobID)
	}
}
