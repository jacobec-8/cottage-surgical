<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->

# Cottage Surgical workflows

Before operating the service or changing a business workflow, read
[docs/AGENT_WORKFLOWS.md](docs/AGENT_WORKFLOWS.md). It maps ordinary requests
(inventory, orders, dates, stores, users, billing, and returns) to required
inputs, UI actions, verification, and implementation files.

Use the user's existing instructions and the current account/store context.
Ask only for missing information that affects the result; do not ask for a
second authorization for an already requested routine action. Distinguish a
new catalog product from additional physical units, and an in-store handoff
from a return pickup. Verify persisted results before reporting completion.

The guide records observations from 2026-10-06, not a live inventory or policy
database. Recheck current state. Older roadmap/schema descriptions can lag the
code; follow the latest applicable migrations and actual deployed behavior.
When changing a documented workflow, update its guide entry and verification
steps with the implementation.
