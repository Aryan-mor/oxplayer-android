package cast

import (
	"testing"
	"time"
)

func TestJobStore(t *testing.T) {
	store := NewJobStore()

	// Test SetJob and GetJob
	job := &CastJob{
		JobID:      "test-job-1",
		ChatID:     "chat-123",
		MessageID:  456,
		FileID:     "file-789",
		FileName:   "test.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}

	store.SetJob("user-1", job)

	retrievedJob, exists := store.GetJob("user-1")
	if !exists {
		t.Fatal("Expected job to exist")
	}
	if retrievedJob.JobID != "test-job-1" {
		t.Errorf("Expected JobID test-job-1, got %s", retrievedJob.JobID)
	}
}

func TestClaimJob(t *testing.T) {
	store := NewJobStore()

	job := &CastJob{
		JobID:      "test-job-2",
		ChatID:     "chat-123",
		MessageID:  456,
		FileID:     "file-789",
		FileName:   "test.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now(),
	}

	store.SetJob("user-2", job)

	// First claim should succeed
	claimedJob, exists := store.ClaimJob("user-2")
	if !exists {
		t.Fatal("Expected job to exist")
	}
	if claimedJob.JobID != "test-job-2" {
		t.Errorf("Expected JobID test-job-2, got %s", claimedJob.JobID)
	}

	// Second claim should fail (job already claimed)
	_, exists = store.ClaimJob("user-2")
	if exists {
		t.Error("Expected job to not exist after claiming")
	}
}

func TestJobExpiration(t *testing.T) {
	store := NewJobStore()

	// Create an old job
	oldJob := &CastJob{
		JobID:      "old-job",
		ChatID:     "chat-123",
		MessageID:  456,
		FileID:     "file-789",
		FileName:   "test.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 1024000,
		CreatedAt:  time.Now().Add(-6 * time.Minute), // 6 minutes ago (expired)
	}

	// Create a recent job
	recentJob := &CastJob{
		JobID:      "recent-job",
		ChatID:     "chat-456",
		MessageID:  789,
		FileID:     "file-012",
		FileName:   "test2.mp4",
		MimeType:   "video/mp4",
		TotalBytes: 2048000,
		CreatedAt:  time.Now().Add(-2 * time.Minute), // 2 minutes ago (not expired)
	}

	store.SetJob("user-old", oldJob)
	store.SetJob("user-recent", recentJob)

	// Run cleanup
	cleanupExpiredJobs(store)

	// Old job should be removed
	_, exists := store.GetJob("user-old")
	if exists {
		t.Error("Expected old job to be removed")
	}

	// Recent job should still exist
	_, exists = store.GetJob("user-recent")
	if !exists {
		t.Error("Expected recent job to still exist")
	}
}
