import { cp, mkdir, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(root, "dist");
const supabaseUrl = (process.env.SUPABASE_URL || "").replace(/\/+$/, "");
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY || "";

if (!/^https:\/\/[A-Za-z0-9.-]+$/.test(supabaseUrl)) {
  throw new Error("SUPABASE_URL must be an HTTPS origin");
}
if (supabaseAnonKey.length < 20 || /YOUR_|SERVICE_ROLE/i.test(supabaseAnonKey)) {
  throw new Error("SUPABASE_ANON_KEY is missing or unsafe");
}

await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });
for (const file of ["index.html", "styles.css", "app.js", "api.js", "_headers"]) {
  await cp(path.join(root, file), path.join(output, file));
}

const config = `window.REMOTE_TASK_CONFIG = ${JSON.stringify({
  supabaseUrl,
  supabaseAnonKey,
})};\n`;
await writeFile(path.join(output, "config.js"), config, { mode: 0o600 });
console.log(`Built ${output}`);

