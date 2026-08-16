import assert from "node:assert/strict";
import { readFile, stat } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

test("build injects public config without a service-role key", async () => {
  const result = spawnSync(process.execPath, ["build.mjs"], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      SUPABASE_URL: "https://fixture.supabase.co",
      SUPABASE_ANON_KEY: "fixture-anon-key-value-1234567890",
      SUPABASE_SERVICE_ROLE_KEY: "must-not-appear",
    },
  });
  assert.equal(result.status, 0, result.stderr);
  const config = await readFile(path.join(root, "dist", "config.js"), "utf8");
  assert.match(config, /fixture\.supabase\.co/);
  assert.match(config, /fixture-anon-key/);
  assert.doesNotMatch(config, /must-not-appear/);
  assert.equal((await stat(path.join(root, "dist", "index.html"))).isFile(), true);
});

