package cast

import (
	"log"
	"time"
)

const (
	// JobTTL is the time-to-live for cast jobs (5 minutes)
	JobTTL = 5 * time.Minute
	// CleanupInterval is how often we check for expired jobs
	CleanupInterval = 1 * time.Minute
)

// StartExpirationCleanup starts a background goroutine that periodically removes expired jobs
func StartExpirationCleanup(store *JobStore) {
	go func() {
		ticker := time.NewTicker(CleanupInterval)
		defer ticker.Stop()

		for range ticker.C {
			cleanupExpiredJobs(store)
		}
	}()
}

// cleanupExpiredJobs removes jobs that have exceeded their TTL
func cleanupExpiredJobs(store *JobStore) {
	now := time.Now()
	jobs := store.GetAllJobs()
	
	expiredCount := 0
	for userID, job := range jobs {
		if now.Sub(job.CreatedAt) > JobTTL {
			store.RemoveJob(userID)
			expiredCount++
			log.Printf("cast: expired job %s for user %s (age: %v)", job.JobID, userID, now.Sub(job.CreatedAt))
		}
	}
	
	if expiredCount > 0 {
		log.Printf("cast: cleaned up %d expired job(s)", expiredCount)
	}
}
