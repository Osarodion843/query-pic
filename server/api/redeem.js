// POST /api/redeem — one-time license redemption.
//
// Body: { "key": "QP-PRO-XXXX-XXXX", "deviceId": "<install id>",
///         "account": "<profile id>" }
// The burn binds device AND account (`usedBy = device::account`):
// two profiles on one phone are two users — the second must not ride
// the first's key. Same composite re-redeeming recovers (backup
// restore); anything else on a used key is rejected.
//   200 {ok:true}                        fresh redeem (now marked used)
//   200 {ok:true, recovered:true}        same device+account re-activating
//   404 {ok:false, error:"unknown"}      no such key (typo or forged)
//   410 {ok:false, error:"used"}         already redeemed elsewhere
//   400/405 for bad method/shape.
//
// Single-use is strict by design: reinstalls and other profiles need a
// support reset (see README) — a used key never unlocks twice.
import { Redis } from "@upstash/redis";
import { keyOf, normalizeKey, KEY_RE } from "../lib/keys.js";

const redis = Redis.fromEnv();

// Subscription windows by plan (monthly/yearly; anything else = 30d).
// The app enforces expiry off the returned validUntil (clock-based, fully
// offline after activation).
const PERIOD_DAYS = { monthly: 30, yearly: 365 };
const periodDaysFor = (plan) =>
  PERIOD_DAYS[String(plan ?? "").toLowerCase()] ?? 30;

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, error: "method-not-allowed" });
  }
  const body = req.body && typeof req.body === "object" ? req.body : {};
  const key = normalizeKey(body.key);
  const deviceId = String(body.deviceId ?? "").trim().slice(0, 128);
  // Profile id is opaque (random, no personal data); it scopes the burn
  // to one user. Empty = pre-account clients (treated as one bucket).
  const account = String(body.account ?? "").trim().slice(0, 128);
  const holder = `${deviceId}::${account}`;
  if (!KEY_RE.test(key)) {
    return res.status(400).json({ ok: false, error: "bad-format" });
  }
  if (!deviceId) {
    return res.status(400).json({ ok: false, error: "missing-device" });
  }
  const record = await redis.hgetall(keyOf(key));
  if (!record || Object.keys(record).length === 0) {
    return res.status(404).json({ ok: false, error: "unknown" });
  }
  if (record.used === "1") {
    if (record.usedBy === holder) {
      return res.status(200).json({
        ok: true,
        recovered: true,
        plan: record.plan ?? "pro",
        validUntil: Number(record.validUntil ?? 0),
      });
    }
    return res.status(410).json({ ok: false, error: "used" });
  }
  const validUntil =
    Date.now() + periodDaysFor(record.plan) * 24 * 3600 * 1000;
  await redis.hset(keyOf(key), {
    used: "1",
    usedBy: holder,
    usedAt: new Date().toISOString(),
    validUntil: String(validUntil),
  });
  return res.status(200).json({
    ok: true,
    plan: record.plan ?? "pro",
    validUntil,
  });
}
