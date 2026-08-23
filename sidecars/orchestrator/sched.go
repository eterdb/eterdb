// The maintenance scheduler: ticks `eter-storage cycle` (WAL flush after
// destructive DDL + WAL/age-gated scheduled base backups + retention) through
// the runner's single-flight lane, replacing `eter-storage daemon` in
// orchestrated deployments. A busy lane (a running recovery) skips the tick,
// the next one fires soon enough, and scheduled backups must never contend
// with a restore for IO. Run EITHER this scheduler OR `eter-storage daemon`,
// never both (double-scheduling = duplicate backups; cost, not corruption).
package main

import (
	"context"
	"time"
)

func scheduleLoop(ctx context.Context, cfg orchConfig, run *runner) {
	tick := time.NewTicker(time.Duration(cfg.scheduleIntervalSec) * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			run.runCycle(ctx)
		}
	}
}
