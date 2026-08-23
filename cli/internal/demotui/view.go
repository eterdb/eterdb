package demotui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/eterdb/eterdb/cli/internal/core"
	"github.com/eterdb/eterdb/cli/internal/demo"
)

// EterDB's palette: Postgres green as the accent, amber for the incident
// build-up, red for the damage. AdaptiveColor keeps it legible on light or dark
// terminals.
var (
	green = lipgloss.AdaptiveColor{Light: "#1f7a44", Dark: "#5fd38a"}
	amber = lipgloss.AdaptiveColor{Light: "#b07d18", Dark: "#febc2e"}
	red   = lipgloss.AdaptiveColor{Light: "#c0392b", Dark: "#ff6b6b"}
	faint = lipgloss.AdaptiveColor{Light: "#888888", Dark: "#9a9a90"}

	accentStyle  = lipgloss.NewStyle().Foreground(green)
	titleStyle   = lipgloss.NewStyle().Foreground(green).Bold(true)
	successStyle = lipgloss.NewStyle().Foreground(green).Bold(true)
	dangerStyle  = lipgloss.NewStyle().Foreground(red).Bold(true)
	warnStyle    = lipgloss.NewStyle().Foreground(amber)
	dimStyle     = lipgloss.NewStyle().Foreground(faint)
	boldStyle    = lipgloss.NewStyle().Bold(true)
	keyStyle     = lipgloss.NewStyle().Foreground(green).Bold(true)

	boxStyle = lipgloss.NewStyle().
			Border(lipgloss.RoundedBorder()).
			BorderForeground(green).
			Padding(1, 3)
)

// contentWidth bounds the story column so long lines wrap and the frame stays
// tidy on wide terminals.
func (m Model) contentWidth() int {
	w := m.width
	if w <= 0 {
		w = 80
	}
	cw := w - 10 // border + padding + margin
	if cw > 72 {
		cw = 72
	}
	if cw < 32 {
		cw = 32
	}
	return cw
}

// View renders the current scene inside a rounded frame.
func (m Model) View() string {
	cw := m.contentWidth()
	var title, body, footer string

	switch m.stage {
	case stageIntro:
		title = animatedLogo(m.logoFrame) + "\n\n" +
			titleStyle.Render("EterDB") + dimStyle.Render("  ·  a drop-in Postgres that can undo")
		body = wrap(
			"It's Postgres (same wire protocol, same SQL) that keeps a reversible "+
				"history of every change. You're about to watch a destructive migration "+
				"wreck a live database, then get surgically reversed. No restore, no backup, "+
				"no downtime.\n\n"+
				dimStyle.Render("Every step below runs against a real database. Nothing is faked."), cw)
		footer = enterHint("seed a live database")

	case stageSeeding:
		title = titleStyle.Render("Seeding")
		body = m.spinner.View() + "planting an e-commerce schema and turning on capture…"
		footer = dimStyle.Render("working…")

	case stageSeeded:
		s := m.seed
		title = successStyle.Render("✓ ") + titleStyle.Render("Database ready")
		body = fmt.Sprintf("%s customers · %s products · %s orders · %s invoices\n",
			boldStyle.Render(itoa(s.Customers)), boldStyle.Render(itoa(s.Products)),
			boldStyle.Render(itoa(s.Orders)), boldStyle.Render(itoa(s.Invoices)))
		body += successStyle.Render("capture: ON") + dimStyle.Render("  · every write from here is reversible")
		if m.recover != nil {
			body += "\n" + successStyle.Render("base backups: automatic")
			if m.snapshot != "" {
				body += dimStyle.Render("  · EterDB just took one: ") + accentStyle.Render(m.snapshot)
			} else {
				body += dimStyle.Render("  · on a schedule, you never run a backup")
			}
		}
		if s.Pgvector {
			body += "\n" + dimStyle.Render("pgvector detected: product embeddings added (compatibility, live)")
		}
		if m.conn != "" {
			body += "\n\n" + dimStyle.Render("This is a real EterDB instance, live at") + "\n"
			body += "  " + accentStyle.Render(m.conn) + "\n"
			body += wrap(dimStyle.Render("Open it in psql or any client in another window and watch the "+
				"incident and the recovery land, row by row, as you step through."), cw)
		}
		footer = enterHint("run the day")

	case stageFiring:
		title = warnStyle.Render("A routine migration runs…")
		if m.applying {
			body = m.spinner.View() + "a migration meant to clear " + boldStyle.Render("draft") + " amounts runs against prod…"
			footer = dimStyle.Render("working…")
		} else {
			// Capture is still draining the seed; show it recording rows so the scene
			// is visibly alive rather than a static spinner that reads as stuck.
			body = m.spinner.View() + "EterDB is recording every change… " +
				accentStyle.Render(addThousands(int64(m.captureRows))+" rows captured")
			footer = dimStyle.Render("catching up to the live database…")
		}

	case stageDamage:
		inc := m.incident
		title = dangerStyle.Render("✗ It forgot its WHERE clause")
		body = wrap("In a single transaction, the migration zeroed "+boldStyle.Render("every invoice amount")+
			", not just the drafts.", cw) + "\n\n"
		body += dangerStyle.Render(fmt.Sprintf("%d invoices wiped to $0.00.", inc.Corrupted)) + "\n\n"
		body += damageTable(inc.Before, inc.After, false) + "\n\n"
		body += wrap(dimStyle.Render("The original amounts are gone. No forward UPDATE can recompute them."), cw)
		footer = enterHint("find out what did this")

	case stageInvestigating:
		title = titleStyle.Render("eter log")
		body = m.spinner.View() + "scanning the most recent transactions…"
		footer = dimStyle.Render("working…")

	case stageLog:
		title = titleStyle.Render("eter log") + dimStyle.Render("  ·  recent transactions, newest first")
		body = logBody(m.log, m.incident.Txid, cw)
		footer = enterHint("ask EterDB about that transaction")

	case stagePreviewing:
		title = titleStyle.Render("eter preview " + itoa64(m.incident.Txid))
		body = m.spinner.View() + "checking what depends on that transaction…"
		footer = dimStyle.Render("working…")

	case stagePreview:
		title = titleStyle.Render("eter preview " + itoa64(m.incident.Txid))
		body = previewBody(m.plan, cw)
		footer = enterHint("reverse it")

	case stageUndoing:
		title = titleStyle.Render("eter undo " + itoa64(m.incident.Txid) + " --apply")
		body = m.spinner.View() + "reversing the transaction, row by row…"
		footer = dimStyle.Render("working…")

	case stageRestored:
		title = successStyle.Render("✓ Reverted") + dimStyle.Render(fmt.Sprintf("  ·  txid %d · %d ops", m.incident.Txid, m.ops))
		body = damageTable(m.incident.After, m.restored, true) + "\n"
		body += successStyle.Render("Every amount restored from the before-image.") +
			dimStyle.Render(" Unrelated writes untouched.")
		if m.recover != nil {
			body += "\n\n" + wrap(dimStyle.Render("Bad row edits are one kind of disaster. What about a dropped table?"), cw)
			footer = enterHint("drop a whole table")
		} else {
			footer = keyStyle.Render("q") + dimStyle.Render(" to quit")
		}

	case stageDropping:
		title = warnStyle.Render("A bad DROP…")
		body = m.spinner.View() + "dropping the entire " + boldStyle.Render("orders") + " table…"
		footer = dimStyle.Render("working…")

	case stageDropped:
		title = dangerStyle.Render("✗ public.orders DROPPED")
		body = wrap("The whole table is gone. Row-level undo can't touch this: there's no row "+
			"to revert to when the object itself is missing.", cw) + "\n\n"
		body += dangerStyle.Render(fmt.Sprintf("%d rows, vanished.", m.ordersBefore)) + "\n\n"
		body += wrap(dimStyle.Render("EterDB has been protecting it all along: base backups run "+
			"automatically on a schedule and every change is in the WAL. Nothing to restore by hand."), cw)
		footer = enterHint("recover the whole table")

	case stageRecovering:
		title = titleStyle.Render("eter recover-table public.orders")
		body = m.spinner.View() + "restoring the base backup, replaying WAL to just before the drop…"
		footer = dimStyle.Render("working…")

	case stageDone:
		title = successStyle.Render("✓ public.orders recovered")
		body = successStyle.Render(fmt.Sprintf("%d rows back", m.ordersAfter)) +
			dimStyle.Render(", restored from the base backup + WAL replay.") + "\n\n"
		body += wrap("Two disasters, both reversed: bad row edits by "+boldStyle.Render("undo")+
			", a dropped table by "+boldStyle.Render("object recovery")+".", cw) + "\n\n"
		body += dimStyle.Render("On your own database:") + "\n"
		for _, c := range []struct{ cmd, desc string }{
			{"eter log", "recent changes + their txids"},
			{"eter undo <txid> --apply", "reverse a transaction"},
			{"eter recover-table <table>", "bring back a dropped table"},
		} {
			body += "  " + accentStyle.Render(c.cmd) +
				dimStyle.Render(strings.Repeat(" ", 28-len(c.cmd))+c.desc) + "\n"
		}
		body = strings.TrimRight(body, "\n")
		footer = keyStyle.Render("q") + dimStyle.Render(" to quit")

	case stageError:
		title = dangerStyle.Render("✗ Something went wrong")
		body = wrap(m.err.Error(), cw) + "\n\n" +
			dimStyle.Render("Is the database reachable? Try:  ") + accentStyle.Render("eter doctor")
		footer = keyStyle.Render("q") + dimStyle.Render(" to quit")
	}

	inner := lipgloss.JoinVertical(lipgloss.Left, title, "", body, "", footer)
	// Width(n) sizes the inner area (including the 6 cols of horizontal padding),
	// so the text content area is n-6; set it to cw+6 so wrapped lines (wrapped to
	// cw) fit exactly and the box never re-wraps them raggedly.
	return "\n" + boxStyle.Width(cw+6).Render(inner) + "\n"
}

// animatedLogo renders one frame of the spinning-ring brand mark (green), the
// living logo shown on the intro/loading screen.
func animatedLogo(frame int) string {
	f := logoFrames[frame%len(logoFrames)]
	out := make([]string, len(f))
	for i, line := range f {
		out[i] = accentStyle.Render("  " + line)
	}
	return strings.Join(out, "\n")
}

// enterHint renders the "▸ press enter to …" call to action.
func enterHint(what string) string {
	return accentStyle.Render("▸ ") + dimStyle.Render("press ") +
		keyStyle.Render("enter") + dimStyle.Render(" to "+what)
}

// previewBody narrates the classification the engine returned. The demo incident
// is clean (nothing read its output), which is the whole point: a safe,
// one-click reversal. A dependent plan is rendered faithfully too.
func previewBody(plan *core.UndoPlan, cw int) string {
	var b strings.Builder
	if plan.Classification == "clean" {
		b.WriteString(successStyle.Render("classification: CLEAN") + dimStyle.Render("  · safe to reverse") + "\n")
		fmt.Fprintf(&b, "%d row changes\n", plan.OpCount)
		b.WriteString(wrap("No later transaction wrote or read what this one wrote, so reversing it can't strand anything downstream.", cw))
	} else {
		b.WriteString(warnStyle.Render("classification: "+strings.ToUpper(plan.Classification)) +
			dimStyle.Render("  · needs review") + "\n")
		fmt.Fprintf(&b, "%d row changes", plan.OpCount)
		if len(plan.Conflicts) > 0 {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  ·  %d later txn(s) depend on it", len(plan.Conflicts))))
		}
		b.WriteString("\n" + wrap("A later transaction read or overwrote these rows, so EterDB will reverse them together.", cw))
	}
	return b.String()
}

// logBody renders the recent transactions the way `eter log` does, with the
// incident transaction called out, so the txid the operator reverses is one
// they discovered here, not one the demo handed them by magic.
func logBody(rows []map[string]any, culprit int64, cw int) string {
	var b strings.Builder
	b.WriteString(dimStyle.Render(fmt.Sprintf("  %-9s %-18s %s", "txid", "table", "change")) + "\n")
	for _, r := range rows {
		txid := numOf(r, "txid")
		table := strOf(r, "table_name")
		change := changeSummary(r)
		line := fmt.Sprintf("  %-9d %-18s %s", txid, table, change)
		if txid == culprit {
			b.WriteString(dangerStyle.Render(line) + dangerStyle.Render("  ← this one") + "\n")
		} else {
			b.WriteString(dimStyle.Render(line) + "\n")
		}
	}
	b.WriteString("\n" + wrap("A single transaction rewrote every invoice. There's the culprit, and its "+
		boldStyle.Render(fmt.Sprintf("txid %d", culprit))+dimStyle.Render("."), cw))
	return strings.TrimRight(b.String(), "\n")
}

// changeSummary turns the per-transaction op counts into "20 rows updated".
func changeSummary(r map[string]any) string {
	for _, op := range []struct {
		key, verb string
	}{{"deletes", "deleted"}, {"updates", "updated"}, {"inserts", "inserted"}} {
		if n := numOf(r, op.key); n > 0 {
			unit := "rows"
			if n == 1 {
				unit = "row"
			}
			return fmt.Sprintf("%d %s %s", n, unit, op.verb)
		}
	}
	return ""
}

// damageTable renders the same four invoices before → after, dollar amounts
// aligned. restore=false colours the changed side as damage (red); restore=true
// colours it as recovery (green). It doubles as the restore table at the end.
func damageTable(before, after []demo.InvoiceRow, restore bool) string {
	byID := make(map[int64]demo.InvoiceRow, len(after))
	for _, r := range after {
		byID[r.ID] = r
	}
	changed := dangerStyle
	if restore {
		changed = successStyle
	}
	var b strings.Builder
	b.WriteString(dimStyle.Render(fmt.Sprintf("  %-8s %12s    %-12s", "invoice", "before", "after")) + "\n")
	for _, from := range before {
		to, ok := byID[from.ID]
		if !ok {
			continue
		}
		fromStr := dimStyle.Render(fmt.Sprintf("%12s", dollars(from.Cents)))
		toStr := dimStyle.Render(fmt.Sprintf("%-12s", dollars(to.Cents)))
		if to.Cents != from.Cents {
			toStr = changed.Render(fmt.Sprintf("%-12s", dollars(to.Cents)))
		}
		fmt.Fprintf(&b, "  %-8s %s  %s %s\n",
			boldStyle.Render("#"+itoa64(from.ID)), fromStr, accentStyle.Render("→"), toStr)
	}
	return strings.TrimRight(b.String(), "\n")
}

// numOf / strOf read a value from an eter.log row map, tolerating the numeric
// types pgx may hand back (int32/int64/float64).
func numOf(m map[string]any, key string) int64 {
	switch x := m[key].(type) {
	case int64:
		return x
	case int32:
		return int64(x)
	case int:
		return int64(x)
	case float64:
		return int64(x)
	}
	return 0
}

func strOf(m map[string]any, key string) string {
	if s, ok := m[key].(string); ok {
		return s
	}
	return ""
}

// dollars renders integer cents as "$1,234.56".
func dollars(cents int64) string {
	neg := cents < 0
	if neg {
		cents = -cents
	}
	whole := cents / 100
	frac := cents % 100
	s := addThousands(whole)
	out := fmt.Sprintf("$%s.%02d", s, frac)
	if neg {
		out = "-" + out
	}
	return out
}

func addThousands(n int64) string {
	s := itoa64(n)
	if len(s) <= 3 {
		return s
	}
	var parts []string
	for len(s) > 3 {
		parts = append([]string{s[len(s)-3:]}, parts...)
		s = s[:len(s)-3]
	}
	parts = append([]string{s}, parts...)
	return strings.Join(parts, ",")
}

// wrap word-wraps to width, preserving explicit newlines.
func wrap(s string, width int) string {
	if width < 20 {
		width = 20
	}
	paras := strings.Split(s, "\n")
	out := make([]string, 0, len(paras))
	for _, para := range paras {
		out = append(out, lipgloss.NewStyle().Width(width).Render(para))
	}
	return strings.Join(out, "\n")
}

func itoa(n int) string     { return fmt.Sprintf("%d", n) }
func itoa64(n int64) string { return fmt.Sprintf("%d", n) }
