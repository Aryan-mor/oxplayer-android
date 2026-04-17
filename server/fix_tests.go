package main

import (
	"fmt"
	"os"
	"regexp"
)

func main() {
	// Read the file
	content, err := os.ReadFile("cast/handlers_test.go")
	if err != nil {
		fmt.Printf("Error reading file: %v\n", err)
		os.Exit(1)
	}

	// Replace the pattern
	re := regexp.MustCompile(`(\s+)store := NewJobStore\(\)\s+handler := NewHandler\(store\)`)
	result := re.ReplaceAllString(string(content), `${1}store := NewJobStore()
${1}deviceStore := NewDeviceStore()
${1}handler := NewHandler(store, deviceStore)`)

	// Write back
	err = os.WriteFile("cast/handlers_test.go", []byte(result), 0644)
	if err != nil {
		fmt.Printf("Error writing file: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("Fixed all NewHandler calls")
}
