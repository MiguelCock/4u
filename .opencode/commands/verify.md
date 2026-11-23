---
description: Run the checks CI runs, for the components that changed
---

Run `bash scripts/verify.sh $ARGUMENTS` from the repo root and report what it
did.

With no arguments it checks the components touched since `origin/develop`
(including untracked files) and expands a `packages/` change to every backend,
as CI does. Naming components (`application`, a `backend-*`, `packages`,
`loadtest`, `docs`, or `all`) runs exactly those.

Report: which components ran, which checks passed or failed, and anything that
was not run (the e2e suite needs the Supabase CLI and the Docker stack). Do not
fix failures in the same step; report them first.
