// Shared license-key helpers (imported by both API routes).
//
// Key format matches the app's offline check exactly
// (`QP-PRO-[A-Z0-9]{4}-[A-Z0-9]{4}`): ambiguous glyphs (0/O, 1/I) are
// excluded for emailed readability — still a subset the app accepts.
//
// Redis layout (Upstash):
//   qp:key:<KEY>    hash {email, plan, amount, currency, event, createdAt,
//                         used (0/1), usedBy, usedAt}
//   qp:event:<id>   "1" with 30-day TTL (Paystack retries webhooks)
//   qp:email:<addr> list of keys (support lookup / resend)
import crypto from "node:crypto";

export const KEY_RE = /^QP-PRO-[A-Z0-9]{4}-[A-Z0-9]{4}$/;
// No 0/O/1/I: readable over email, still matches KEY_RE.
const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export function generateKey() {
  const bytes = crypto.randomBytes(8);
  let s = "";
  for (const b of bytes) s += ALPHABET[b % ALPHABET.length];
  return `QP-PRO-${s.slice(0, 4)}-${s.slice(4, 8)}`;
}

export function normalizeKey(raw) {
  return String(raw ?? "").trim().toUpperCase();
}

export const keyOf = (key) => `qp:key:${key}`;
export const eventOf = (id) => `qp:event:${id}`;
export const emailOf = (addr) =>
  `qp:email:${String(addr ?? "").trim().toLowerCase()}`;
