# Verification record

Date: 2026-08-17

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

## Test commands

```sh
python3 -m unittest discover -s remote-system/agent/tests -v
python3 -m unittest discover -s remote-system/tests -v
npm test --prefix remote-system/web
```

Literal summary, exit status `0`:

```text
Ran 6 tests in 0.173s
OK
Ran 14 tests in 0.000s
OK
tests 13
pass 13
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

## Artifacts

- Windows Agent package: `releases/unified-task-agent-windows.zip`
- Package SHA-256: `bdd33c2319593a63db3a7d1f69129b2a91a697ae0e9040f3ce38f2f85f9e2048`
- Implementation patch: `../artifacts/remote-system-logic-restore-20260816/implementation.patch`
- Local rollback: `../artifacts/remote-system-logic-restore-20260816/rollback.sh`
- Desktop preview: `../artifacts/remote-system-logic-restore-20260816/web-desktop.png`
- Mobile preview: `../artifacts/remote-system-logic-restore-20260816/web-mobile.png`
- Legacy cloud export: retained outside this repository

## External verification still required

- The live Supabase project still has the older migrations active; `0004_admin_console_and_invitation_rotation.sql` must be run in the Supabase SQL Editor. A live RPC probe returned `404` for `admin_list_remote_users`, confirming that the new database function is not deployed yet.
- Run all four migrations in order before publishing the matching web build. The new migration immediately normalizes today's available-code pool to 10 and preserves already used rows.
- GitHub Pages preview deployment succeeded in workflow `31950231672` at `https://wzq522.github.io/welearn-remote/`.
- Desktop width `1280` and mobile width `390` were rendered in the local browser. Both reported zero horizontal overflow; the mobile input counter changed from `0` to `2` for two non-empty lines.
