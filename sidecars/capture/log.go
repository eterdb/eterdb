// Minimal structured logging to stderr (stdout stays clean for any future
// machine-readable output, mirroring the CLI's discipline).
package main

import (
	"encoding/json"
	"os"
	"time"
)

func logEmit(level, msg string, extra map[string]any) {
	line := map[string]any{
		"ts":    time.Now().UTC().Format(time.RFC3339Nano),
		"level": level,
		"comp":  "capture",
		"msg":   msg,
	}
	for k, v := range extra {
		line[k] = v
	}
	b, _ := json.Marshal(line)
	_, _ = os.Stderr.Write(append(b, '\n'))
}

func logInfo(msg string, extra map[string]any)  { logEmit("info", msg, extra) }
func logWarn(msg string, extra map[string]any)  { logEmit("warn", msg, extra) }
func logError(msg string, extra map[string]any) { logEmit("error", msg, extra) }
