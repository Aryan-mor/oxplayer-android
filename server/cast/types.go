package cast

import (
	"sync"
	"time"
)

// CastJob represents a media cast job stored in memory
type CastJob struct {
	JobID        string                 `json:"jobId"`
	ChatID       string                 `json:"chatId"`
	MessageID    int64                  `json:"messageId"`
	FileID       string                 `json:"fileId"`
	FileName     string                 `json:"fileName"`
	MimeType     string                 `json:"mimeType"`
	TotalBytes   int64                  `json:"totalBytes"`
	ThumbnailURL *string                `json:"thumbnailUrl,omitempty"`
	Metadata     map[string]interface{} `json:"metadata,omitempty"`
	CreatedAt    time.Time              `json:"createdAt"`
}

// CreateCastJobRequest represents the request payload for creating a cast job
type CreateCastJobRequest struct {
	ChatID       string                 `json:"chatId"`
	MessageID    int64                  `json:"messageId"`
	FileID       string                 `json:"fileId"`
	FileName     string                 `json:"fileName"`
	MimeType     string                 `json:"mimeType"`
	TotalBytes   int64                  `json:"totalBytes"`
	ThumbnailURL *string                `json:"thumbnailUrl,omitempty"`
	Metadata     map[string]interface{} `json:"metadata,omitempty"`
}

// ClaimJobResponse represents the response when claiming a cast job
type ClaimJobResponse struct {
	JobID        string                 `json:"jobId"`
	ChatID       string                 `json:"chatId"`
	MessageID    int64                  `json:"messageId"`
	FileID       string                 `json:"fileId"`
	FileName     string                 `json:"fileName"`
	MimeType     string                 `json:"mimeType"`
	TotalBytes   int64                  `json:"totalBytes"`
	ThumbnailURL *string                `json:"thumbnailUrl,omitempty"`
	Metadata     map[string]interface{} `json:"metadata,omitempty"`
	CreatedAt    time.Time              `json:"createdAt"`
}

// JobStore manages in-memory storage of cast jobs
type JobStore struct {
	jobs map[string]*CastJob // keyed by userId
	mu   sync.RWMutex
}

// NewJobStore creates a new JobStore instance
func NewJobStore() *JobStore {
	return &JobStore{
		jobs: make(map[string]*CastJob),
	}
}

// SetJob stores a cast job for a user
func (s *JobStore) SetJob(userID string, job *CastJob) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.jobs[userID] = job
}

// GetJob retrieves a cast job for a user
func (s *JobStore) GetJob(userID string) (*CastJob, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	job, exists := s.jobs[userID]
	return job, exists
}

// ClaimJob atomically retrieves and removes a cast job for a user
func (s *JobStore) ClaimJob(userID string) (*CastJob, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	job, exists := s.jobs[userID]
	if exists {
		delete(s.jobs, userID)
	}
	return job, exists
}

// RemoveJob removes a cast job for a user
func (s *JobStore) RemoveJob(userID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.jobs, userID)
}

// GetAllJobs returns all jobs (for cleanup purposes)
func (s *JobStore) GetAllJobs() map[string]*CastJob {
	s.mu.RLock()
	defer s.mu.RUnlock()
	// Return a copy to avoid race conditions
	jobsCopy := make(map[string]*CastJob, len(s.jobs))
	for k, v := range s.jobs {
		jobsCopy[k] = v
	}
	return jobsCopy
}

// DeviceRegistration represents a registered device for FCM push notifications
type DeviceRegistration struct {
	DeviceID   string `json:"deviceId"`
	FCMToken   string `json:"fcmToken"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion"`
	UserID     string `json:"-"` // Not exposed in JSON
}

// RegisterDeviceRequest represents the request payload for device registration
type RegisterDeviceRequest struct {
	DeviceID   string `json:"deviceId"`
	FCMToken   string `json:"fcmToken"`
	Platform   string `json:"platform"`
	AppVersion string `json:"appVersion"`
}

// DeviceStore manages in-memory storage of device registrations
// In production, this would be replaced with database storage
type DeviceStore struct {
	// Map of userId -> deviceId -> DeviceRegistration
	devices map[string]map[string]*DeviceRegistration
	mu      sync.RWMutex
}

// NewDeviceStore creates a new DeviceStore instance
func NewDeviceStore() *DeviceStore {
	return &DeviceStore{
		devices: make(map[string]map[string]*DeviceRegistration),
	}
}

// RegisterDevice stores a device registration for a user
func (s *DeviceStore) RegisterDevice(userID string, device *DeviceRegistration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	
	if s.devices[userID] == nil {
		s.devices[userID] = make(map[string]*DeviceRegistration)
	}
	
	s.devices[userID][device.DeviceID] = device
}

// GetDevices retrieves all registered devices for a user
func (s *DeviceStore) GetDevices(userID string) []*DeviceRegistration {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	userDevices := s.devices[userID]
	if userDevices == nil {
		return nil
	}
	
	devices := make([]*DeviceRegistration, 0, len(userDevices))
	for _, device := range userDevices {
		devices = append(devices, device)
	}
	return devices
}

// GetDevice retrieves a specific device registration
func (s *DeviceStore) GetDevice(userID, deviceID string) (*DeviceRegistration, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	
	userDevices := s.devices[userID]
	if userDevices == nil {
		return nil, false
	}
	
	device, exists := userDevices[deviceID]
	return device, exists
}
