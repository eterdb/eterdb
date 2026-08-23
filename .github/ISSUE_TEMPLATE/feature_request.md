---
name: Feature request
about: Suggest an idea or improvement
title: ""
labels: enhancement
---

**The problem**
What are you trying to do that EterDB doesn't (cleanly) support today?

**Proposed direction**
What would a good solution look like? (Rough is fine.)

**Alternatives considered**
Anything you've tried or ruled out.

**Scope note**
EterDB reverses **database state** and recovers destructive schema changes; it does
not undo external side-effects (emails, charges), it surfaces them. Requests that fit
that boundary are easiest to accept.
