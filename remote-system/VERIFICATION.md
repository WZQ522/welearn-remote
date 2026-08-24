# Verification record

Date: 2026-08-24

## Delivered behavior

- Registration requires a current invitation code; each code is consumed atomically once, and the daily `pg_cron` job issues multiple random codes.
- Login creates a 30-day session whose raw token is kept only in the browser; task RPCs verify both session ownership and the per-submission receipt token.
- Static mobile page submits the original per-line account batch format through Supabase RPC using only the anon key.
- A random per-submission receipt token gates status, cancel, retry, and clear calls.
- PostgreSQL stores pending tasks while the computer is offline.
- `claim_next_submission` uses `FOR UPDATE SKIP LOCKED` and heartbeat leases.
- The Windows Agent writes `submission_id`, `raw_text`, and `line_count`, then invokes `my-program.exe --input input.json --output result.json` through one adapter module.
- The mock processor reports `execution_status`, `task_total`, `task_completed`, `task_failed`, and `result_message` for the full claim, process, and upload path.
- Task Scheduler scripts start and restart the Agent after Windows logon.
- The admin console rotates today's unused invitation codes to a fixed set of 10, retains consumed-code history with the consuming account, and lists all registered accounts without password hashes.
- Admins can reset ordinary-account passwords to `11111111` or delete ordinary accounts; admin accounts and the current admin session are protected.
- The score-history and legacy receipt-status RPCs project only `score_summary`; neither returns the full processor result payload to the browser.
- Migration `0018` redacts `raw_text` immediately for completed/failed tasks, deletes canceled rows immediately, removes completed/failed rows after 3 days, retains billing ledger rows via `ON DELETE SET NULL`, and the web requests at most 50 recent task rows.

## Test commands

```sh
python3 -m unittest discover -s remote-system/agent/tests -v
python3 -m unittest discover -s remote-system/tests -v
npm test --prefix remote-system/web
```

Literal summary, exit status `0`:

```text
Ran 9 tests in 0.173s
OK
Ran 34 tests in 0.001s
OK
tests 30
pass 30
fail 0
```

The Agent configuration preflight also returned:

```json
{"ok": true, "agent_id": "verification-agent"}
```

The preflight used fixture values and did not contact Supabase.

## Security and cleanup checks

- The local Agent `.env` exists only for desktop runtime configuration and is excluded from the public web build; no service-role credential is embedded in source or generated web config.
- No JWT-shaped or service-role credential literal was found.
- No old Worker address, CloudBase environment ID, old API path, Secret name, webhook, Cron entry, or LaunchAgent remains in active code.
- The public web build test proves `SUPABASE_SERVICE_ROLE_KEY` is not copied into `dist/config.js`.
- RLS tests prove anon/authenticated roles have no direct table permission.
- Migration `0013_auth_rate_limits.sql` adds database-side limits for repeated login and invitation attempts; deploy it after `0012` before exposing registration publicly.

## Artifacts

- Windows Agent package: `releases/unified-task-agent-windows.zip`
- Package SHA-256: `bdd33c2319593a63db3a7d1f69129b2a91a697ae0e9040f3ce38f2f85f9e2048`
- Implementation patch: `../artifacts/remote-system-logic-restore-20260816/implementation.patch`
- Local rollback: `../artifacts/remote-system-logic-restore-20260816/rollback.sh`
- Desktop preview: `../artifacts/remote-system-logic-restore-20260816/web-desktop.png`
- Mobile preview: `../artifacts/remote-system-logic-restore-20260816/web-mobile.png`
- Legacy cloud export: retained outside this repository

## External verification

- The live Supabase project has migrations through `0017_submission_owner_projection.sql`. On 2026-08-20, the claim-function definition was verified to contain `submitted_by`; anonymous admin probes reached the normal `admin_required` guard, while direct execution of the private `is_remote_admin` helper was denied.
- Run migrations `0001` through `0018` in order before publishing the matching desktop/web builds. `0011` and `0012` keep processor payloads private, `0013` rate-limits authentication attempts, `0015`/`0016` provide wallet billing and its private admin-session helper, `0017` supplies the website submitter name only to the service-role Agent claim, and `0018` enforces short task retention.
- GitHub Pages preview deployment succeeded in workflow `31950231672` at `https://wzq522.github.io/welearn-remote/`.
- Desktop width `1280` and mobile width `390` were rendered in the local browser. Both reported zero horizontal overflow; the mobile input counter changed from `0` to `2` for two non-empty lines.
