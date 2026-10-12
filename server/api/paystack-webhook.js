// POST /api/paystack-webhook — Paystack `charge.success` fulfillment.
//
// Verifies the Paystack HMAC signature over the RAW body, enforces
// idempotency on the event id (Paystack retries!), mints a single-use
// key, stores it active, indexes by email, and emails it via Resend.
// Email failure never fails the webhook (key is stored first; support
// can resend from the email index).
//
// Vercel: raw body required -> bodyParser OFF (see export below).
import crypto from "node:crypto";
import { Redis } from "@upstash/redis";
import { Resend } from "resend";
import { emailOf, eventOf, generateKey, keyOf } from "../lib/keys.js";

export const config = { api: { bodyParser: false } };

const redis = Redis.fromEnv();
const resend = () => new Resend(process.env.RESEND_API_KEY);

async function sendKeyEmail({ email, key, plan, amountDisplay }) {
  // Returns true when Resend accepted it. Never throws (callers treat
  // email as best-effort: the key is always stored first).
  if (!email || !process.env.RESEND_API_KEY || !process.env.MAIL_FROM) {
    return false;
  }
  try {
    const app = process.env.APP_NAME || "QueryPic";
    const { error } = await resend().emails.send({
      from: process.env.MAIL_FROM,
      to: email,
      subject: `${app} Pro — your license key`,
      html:
        `<p>Thanks for going Pro! Your license key (one device, keep it private):</p>` +
        `<p style="font-size:22px;font-weight:bold;letter-spacing:2px">${key}</p>` +
        `<p>Enter it in ${app} under <b>Settings → Enter license key</b>. ` +
        `The app then works fully offline.</p>` +
        `<p>Plan: ${plan} · Amount: ${amountDisplay}</p>`,
    });
    if (error) {
      console.error("resend failed:", JSON.stringify(error));
      return false;
    }
    return true;
  } catch (e) {
    console.error("resend threw:", e?.message ?? e);
    return false;
  }
}

async function readRaw(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function signatureOk(raw, header) {
  if (!header || !process.env.PAYSTACK_SECRET_KEY) return false;
  const digest = crypto
    .createHmac("sha512", process.env.PAYSTACK_SECRET_KEY)
    .update(raw)
    .digest("hex");
  const a = Buffer.from(digest);
  const b = Buffer.from(String(header));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export default async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ ok: false, error: "method-not-allowed" });
  }
  const raw = await readRaw(req);
  if (!signatureOk(raw, req.headers["x-paystack-signature"])) {
    return res.status(401).json({ ok: false, error: "bad-signature" });
  }
  let event;
  try {
    event = JSON.parse(raw.toString("utf8"));
  } catch {
    return res.status(400).json({ ok: false, error: "bad-json" });
  }
  if (event?.event !== "charge.success" || event?.data?.status !== "success") {
    return res.status(200).json({ ok: true, ignored: true });
  }
  const data = event.data;
  const eventKey = eventOf(data.id ?? `${data.reference}`);
  if (await redis.exists(eventKey)) {
    return res.status(200).json({ ok: true, duplicate: true });
  }

  const email = data.customer?.email ?? "";
  // Paystack amounts are MINOR units (kobo/cents): 300000 = NGN 3,000.00.
  // Store raw minor units (exact); format only for display.
  const amountMinor = data.amount ?? 0;
  const currency = data.currency ?? "";
  const plan = data.metadata?.plan ?? "pro";
  const amountDisplay = `${(amountMinor / 100).toLocaleString("en-NG", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })} ${currency}`;

  // Double-tap guard: same email + same amount within 30 min reuses the
  // still-unredeemed key instead of minting — AND still emails it, so
  // every successful payment yields exactly one email (previously the
  // reuse path went silent, which read as "sometimes no email").
  if (email) {
    try {
      const prior = await redis.lrange(emailOf(email), 0, -1);
      for (const oldKey of prior) {
        const rec = await redis.hgetall(keyOf(oldKey));
        if (!rec || Object.keys(rec).length === 0) continue;
        if (rec.used === "1") continue;
        if (Number(rec.amountMinor ?? -1) !== amountMinor) continue;
        const ageMs = Date.now() - Date.parse(rec.createdAt ?? 0);
        if (Number.isFinite(ageMs) && ageMs < 30 * 60 * 1000) {
          await redis.set(eventKey, "1", { ex: 60 * 60 * 24 * 30 });
          const emailed = await sendKeyEmail({
            email,
            key: oldKey,
            plan: rec.plan ?? plan,
            amountDisplay: rec.amountDisplay ?? amountDisplay,
          });
          return res.status(200).json({ ok: true, reused: oldKey, emailed });
        }
      }
    } catch (e) {
      console.error("reuse check failed (minting fresh):", e?.message ?? e);
    }
  }

  // Collision-safe mint (8 chars from 32-symbol alphabet: 2^40 space).
  let key = "";
  for (let i = 0; i < 5; i++) {
    const candidate = generateKey();
    if (!(await redis.exists(keyOf(candidate)))) {
      key = candidate;
      break;
    }
  }
  if (!key) return res.status(500).json({ ok: false, error: "mint-failed" });

  const now = new Date().toISOString();
  await redis.hset(keyOf(key), {
    email,
    plan,
    amountMinor: String(amountMinor),
    amountDisplay,
    currency,
    event: String(data.id ?? data.reference ?? ""),
    createdAt: now,
    used: "0",
    usedBy: "",
    usedAt: "",
  });
  if (email) await redis.rpush(emailOf(email), key);
  await redis.set(eventKey, "1", { ex: 60 * 60 * 24 * 30 });

  // Email last and non-fatal: the key is already safely stored.
  const emailed = await sendKeyEmail({ email, key, plan, amountDisplay });
  return res.status(200).json({ ok: true, emailed });
}
