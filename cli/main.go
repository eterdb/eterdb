// Command eter is the EterDB CLI: see and surgically reverse live Postgres
// transactions. This is the Go port of the original TypeScript CLI; the command
// surface, JSON shapes, and exit codes are preserved as a frozen interface.
package main

import (
	"context"
	"os"

	"github.com/eterdb/eterdb/cli/internal/cmd"
)

func main() {
	os.Exit(cmd.Execute(context.Background(), os.Args[1:]))
}
