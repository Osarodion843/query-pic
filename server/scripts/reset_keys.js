// License-key inspector + reset tool (run locally, NOT deployed).
//
// Lists every minted key with its burn state, or resets all burns.
// Needs Upstash REST credentials in the environment (same values as
// the Vercel env vars):
//
//   $env:UPSTASH_REDIS_REST_URL="https://...upstash.io"
//   $env:UPSTASH_REDIS_REST_TOKEN="..."
//   node tools/reset_keys.js            # list only (safe)
//   node tools/reset_keys.js --reset    # clear used/usedBy/usedAt on ALL
//
// How to read a row: used=0 → fresh, redeemable. used=1 → burned;
// usedBy is "<install-id>::<profile-id>" (new rule) or a bare install
// id (burned before the composite rule — still enforced, just less
// specific). usedAt/validUntil are ISO/ms timestamps.
import { Redis } from "@upstash/redis";

const redis = Redis.fromEnv();
const reset = process.argv.includes("--reset");

const keys = await redis.keys("qp:key:*");
if (keys.length === 0) {
  console.log("no license keys minted yet.");
  process.exit(0);
}
for (const k of keys.sort()) {
  const h = await redis.hgetall(k);
  const name = k.replace(/^qp:key:/, "");
  const state = h.used === "1" ? "USED " : "fresh";
  console.log(
    `${state} ${name} plan=${h.plan ?? "?"} ` +
      `by=${h.usedBy || "-"} at=${h.usedAt || h.createdAt || "-"}`,
  );
  if (reset && h.used === "1") {
    await redis.hset(k, { used: "0", usedBy: "", usedAt: "" });
    console.log(`   -> reset to fresh`);
  }
}
console.log(reset ? "done." : "list only; re-run with --reset to burn-reset all.");
