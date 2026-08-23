// `eter jobs`, inspect/cancel the orchestrator's storage jobs. Orchestrator
// (hosted) mode only: in direct mode there is no job queue, so the command
// exits with a config error pointing at `eter connect --url`.

package cmd

import (
	"context"
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/eterdb/eterdb/cli/internal/client"
	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/output"
)

func newJobsCmd(g *globalOpts) *cobra.Command {
	var limit int
	var cancel bool
	cmd := &cobra.Command{
		Use:     "jobs [job-id]",
		Short:   "list orchestrator storage jobs, or show/cancel one",
		Args:    cobra.MaximumNArgs(1),
		Example: "  eter jobs\n  eter jobs 42\n  eter jobs 42 --cancel",
		RunE: func(cmd *cobra.Command, args []string) error {
			return withClient(cmd, g, func(ctx context.Context, c client.EterClient) error {
				jc, ok := c.(client.JobClient)
				if !ok {
					return fail(core.ExitConfig,
						"jobs need an orchestrator: connect with `eter connect --url <orchestrator>` or set ETER_URL + ETER_TOKEN")
				}
				if len(args) == 0 {
					if cancel {
						return fail(core.ExitUsage, "--cancel needs a job id: eter jobs <id> --cancel")
					}
					rows, err := jc.ListJobs(ctx, limit)
					if err != nil {
						return err
					}
					output.Emit(rows, func() {
						output.Table(rows, []string{"id", "kind", "state", "submitted_at", "finished_at", "error"})
					})
					return nil
				}
				id, err := strconv.ParseInt(args[0], 10, 64)
				if err != nil {
					return fail(core.ExitUsage, "invalid job id "+args[0])
				}
				if cancel {
					if err := jc.CancelJob(ctx, id); err != nil {
						return err
					}
					output.Emit(map[string]any{"ok": true, "canceled": true, "job_id": id}, func() {
						fmt.Printf("✓ canceled job %d\n", id)
					})
					return nil
				}
				job, err := jc.GetJob(ctx, id)
				if err != nil {
					return err
				}
				output.Emit(job, func() {
					fmt.Printf("job %v: %v (%v)\n", job["id"], job["state"], job["kind"])
					if p, ok := job["progress"].(map[string]any); ok && p["msg"] != nil {
						fmt.Printf("  progress: %v\n", p["msg"])
					}
					if e, ok := job["error"].(string); ok && e != "" {
						fmt.Printf("  error: %s\n", e)
					}
					if out, ok := job["output"].(map[string]any); ok && out != nil {
						fmt.Printf("  output: %s\n", output.Fmt(out))
					}
				})
				return nil
			})
		},
	}
	cmd.Flags().IntVar(&limit, "limit", 20, "max jobs to list")
	cmd.Flags().BoolVar(&cancel, "cancel", false, "cancel the given job")
	return cmd
}
