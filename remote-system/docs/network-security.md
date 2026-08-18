# Network Security Model

## What Is Exposed

- GitHub Pages or Cloudflare Pages serves only static files. It is not a server running on the home computer, so public DNS for the site does not point at the computer's public IP.
- The Supabase project URL is visible to the browser by design. It identifies the public API service, not the home computer. Database access is limited by RPC grants, RLS, session ownership checks, and the public anon key.
- The desktop Agent makes outbound HTTPS requests to Supabase and starts the local processor as a child process. It has no HTTP server, WebSocket listener, inbound port, UPnP rule, or port-forwarding requirement.

## Required Deployment Rules

1. Keep `remote-system/agent/.env` only on the desktop that runs the Agent. Never put `SUPABASE_SERVICE_ROLE_KEY` in `web/config.js`, `web/dist`, GitHub repository variables used by the browser, screenshots, or issue reports.
2. Publish the web console through GitHub Pages or Cloudflare Pages over HTTPS. Do not run the static page with a home-directory web server or expose a development server.
3. Do not configure router port forwarding, UPnP, DDNS, or an inbound firewall exception for the Agent. The queue is retained by Supabase while the computer is offline.
4. Apply migrations `0001` through `0013` in order. Migration `0013` rate-limits repeated login and invitation attempts inside PostgreSQL; the browser cannot disable that limit.
5. Keep the service-role key out of build logs. GitHub Actions may receive only `SUPABASE_URL` and `SUPABASE_ANON_KEY` for the static build.

## If Egress IP Must Also Be Masked

The public site already avoids exposing the desktop IP. Supabase can still observe the Agent's outbound source IP because it is the destination service. To mask that egress IP, use an operating-system or router-level HTTPS proxy/VPN that you control; configure it outside the web page. Python's standard `urllib` honors the usual `HTTPS_PROXY` environment setting. A Cloudflare Tunnel is for inbound publishing and does not by itself anonymize arbitrary outbound Agent requests.

## Verification Commands

```sh
# Confirm the Agent has no listening socket in its source.
rg -n "HTTPServer|TCPServer|WebSocket|listen\(|socket\.bind|serve_forever" remote-system/agent

# Confirm secrets are not present in the web build or tracked files.
rg -n --hidden --glob '!**/.git/**' --glob '!**/node_modules/**' \
  'SUPABASE_SERVICE_ROLE_KEY|service_role|BEGIN .*PRIVATE KEY' remote-system/web remote-system/web/dist

# Inspect the public deployment response headers.
curl -sSI https://YOUR_PAGES_HOST/ | rg -i 'strict-transport|content-security|frame|referrer|permissions|cross-origin'
```

The final command must be run against the actual deployed host after publishing. A public Supabase URL may remain visible in browser network tools; that is expected and is protected by database authorization rather than secrecy.
