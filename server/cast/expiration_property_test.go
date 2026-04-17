package cast

import (
	"testing"
	"time"

	"github.com/leanovate/gopter"
	"github.com/leanovate/gopter/gen"
	"github.com/leanovate/gopter/prop"
)

// Feature: relay-tv-cast, Property 15: Job Expiration
// **Validates: Requirements 11.5**
//
// Property: For any cast job, if the job age exceeds 5 minutes, the backend SHALL automatically remove it from memory.
func TestProperty_JobExpiration(t *testing.T) {
	parameters := gopter.DefaultTestParameters()
	parameters.MinSuccessfulTests = 100
	properties := gopter.NewProperties(parameters)

	properties.Property("jobs older than 5 minutes are automatically removed", prop.ForAll(
		func(jobAge time.Duration, numJobs int) bool {
			store := NewJobStore()

			// Create jobs with various ages
			now := time.Now()
			userIDs := make([]string, numJobs)
			expectedRemoved := 0
			expectedKept := 0

			for i := 0; i < numJobs; i++ {
				userID := generateUserID(i)
				userIDs[i] = userID

				// Calculate job creation time based on age
				createdAt := now.Add(-jobAge)
				if i%2 == 0 {
					// Even indices: add extra time to make some jobs expired
					createdAt = createdAt.Add(-time.Duration(i) * time.Minute)
				}

				job := &CastJob{
					JobID:      generateJobID(i),
					ChatID:     "chat-test",
					MessageID:  int64(i),
					FileID:     "file-test",
					FileName:   "test.mp4",
					MimeType:   "video/mp4",
					TotalBytes: 1024000,
					CreatedAt:  createdAt,
				}

				store.SetJob(userID, job)

				// Track expected results
				if now.Sub(createdAt) > JobTTL {
					expectedRemoved++
				} else {
					expectedKept++
				}
			}

			// Run cleanup
			cleanupExpiredJobs(store)

			// Verify results
			actualKept := 0
			actualRemoved := 0

			for _, userID := range userIDs {
				_, exists := store.GetJob(userID)
				if exists {
					actualKept++
				} else {
					actualRemoved++
				}
			}

			// Property: All jobs older than 5 minutes should be removed
			// All jobs younger than 5 minutes should be kept
			return actualRemoved == expectedRemoved && actualKept == expectedKept
		},
		gen.TimeRange(time.Minute, 10*time.Minute), // Job ages from 1 to 10 minutes
		gen.IntRange(1, 20),                         // Number of jobs from 1 to 20
	))

	properties.TestingRun(t)
}

// TestProperty_JobExpirationBoundary tests the exact boundary condition (5 minutes)
func TestProperty_JobExpirationBoundary(t *testing.T) {
	parameters := gopter.DefaultTestParameters()
	parameters.MinSuccessfulTests = 100
	properties := gopter.NewProperties(parameters)

	properties.Property("jobs at exactly 5 minutes boundary are handled correctly", prop.ForAll(
		func(offsetMillis int64) bool {
			store := NewJobStore()
			now := time.Now()

			// Create a job at exactly 5 minutes + offset (in milliseconds)
			offset := time.Duration(offsetMillis) * time.Millisecond
			createdAt := now.Add(-JobTTL).Add(-offset)

			job := &CastJob{
				JobID:      "boundary-job",
				ChatID:     "chat-test",
				MessageID:  123,
				FileID:     "file-test",
				FileName:   "test.mp4",
				MimeType:   "video/mp4",
				TotalBytes: 1024000,
				CreatedAt:  createdAt,
			}

			store.SetJob("boundary-user", job)

			// Run cleanup
			cleanupExpiredJobs(store)

			// Check if job exists
			_, exists := store.GetJob("boundary-user")

			// Property: Job should be removed if age > 5 minutes
			age := now.Sub(createdAt)
			shouldBeRemoved := age > JobTTL

			return exists != shouldBeRemoved // exists should be opposite of shouldBeRemoved
		},
		gen.Int64Range(-1000, 1000), // Offset from -1 second to +1 second around the 5-minute boundary
	))

	properties.TestingRun(t)
}

// TestProperty_JobExpirationPreservesRecentJobs tests that recent jobs are never removed
func TestProperty_JobExpirationPreservesRecentJobs(t *testing.T) {
	parameters := gopter.DefaultTestParameters()
	parameters.MinSuccessfulTests = 100
	properties := gopter.NewProperties(parameters)

	properties.Property("jobs younger than 5 minutes are never removed", prop.ForAll(
		func(jobAge time.Duration, numJobs int) bool {
			store := NewJobStore()
			now := time.Now()

			userIDs := make([]string, numJobs)

			for i := 0; i < numJobs; i++ {
				userID := generateUserID(i)
				userIDs[i] = userID

				// All jobs are recent (younger than 5 minutes)
				createdAt := now.Add(-jobAge)

				job := &CastJob{
					JobID:      generateJobID(i),
					ChatID:     "chat-test",
					MessageID:  int64(i),
					FileID:     "file-test",
					FileName:   "test.mp4",
					MimeType:   "video/mp4",
					TotalBytes: 1024000,
					CreatedAt:  createdAt,
				}

				store.SetJob(userID, job)
			}

			// Run cleanup
			cleanupExpiredJobs(store)

			// Verify all jobs still exist
			allExist := true
			for _, userID := range userIDs {
				_, exists := store.GetJob(userID)
				if !exists {
					allExist = false
					break
				}
			}

			// Property: All recent jobs should be preserved
			return allExist
		},
		gen.TimeRange(0, JobTTL-time.Second), // Job ages from 0 to just under 5 minutes
		gen.IntRange(1, 20),                  // Number of jobs from 1 to 20
	))

	properties.TestingRun(t)
}

// TestProperty_JobExpirationRemovesAllExpiredJobs tests that all expired jobs are removed
func TestProperty_JobExpirationRemovesAllExpiredJobs(t *testing.T) {
	parameters := gopter.DefaultTestParameters()
	parameters.MinSuccessfulTests = 100
	properties := gopter.NewProperties(parameters)

	properties.Property("all jobs older than 5 minutes are removed", prop.ForAll(
		func(jobAge time.Duration, numJobs int) bool {
			store := NewJobStore()
			now := time.Now()

			userIDs := make([]string, numJobs)

			for i := 0; i < numJobs; i++ {
				userID := generateUserID(i)
				userIDs[i] = userID

				// All jobs are expired (older than 5 minutes)
				createdAt := now.Add(-JobTTL).Add(-jobAge)

				job := &CastJob{
					JobID:      generateJobID(i),
					ChatID:     "chat-test",
					MessageID:  int64(i),
					FileID:     "file-test",
					FileName:   "test.mp4",
					MimeType:   "video/mp4",
					TotalBytes: 1024000,
					CreatedAt:  createdAt,
				}

				store.SetJob(userID, job)
			}

			// Run cleanup
			cleanupExpiredJobs(store)

			// Verify all jobs are removed
			allRemoved := true
			for _, userID := range userIDs {
				_, exists := store.GetJob(userID)
				if exists {
					allRemoved = false
					break
				}
			}

			// Property: All expired jobs should be removed
			return allRemoved
		},
		gen.TimeRange(time.Second, 10*time.Minute), // Additional age beyond 5 minutes
		gen.IntRange(1, 20),                         // Number of jobs from 1 to 20
	))

	properties.TestingRun(t)
}

// Helper functions

func generateUserID(index int) string {
	return "user-" + string(rune('A'+index%26)) + string(rune('0'+index/26))
}

func generateJobID(index int) string {
	return "job-" + string(rune('A'+index%26)) + string(rune('0'+index/26))
}
