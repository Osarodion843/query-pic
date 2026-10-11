# QueryPic license server (serverless)

Single-use Pro keys: Paystack `charge.success` → key minted + stored
active → emailed → app redeems once. No user accounts server-side; the
only stored PII is the purchaser email (needed to deliver the key).

## Deploy (Vercel, free tier)

1. `cd server && npm install`
2. `npx vercel` (or import the repo in the Vercel dashboard, root
   directory `server/`), Node 20+.
3. Add Environment Variables from `.env.example` (use **live** Paystack
   secret when going live; test secret for test mode):
   - `PAYSTACK_SECRET_KEY`
   - `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` (Upstash
     console → your database → REST API; free tier is plenty)
   - `RESEND_API_KEY` + `MAIL_FROM` (verify the sender domain in Resend;
     free: 100 emails/day)
4. Note the deployment URL, e.g.
   `https://querypic-license.vercel.app`, and paste it into the app as
   `BackendKeys.licenseApiBase` (see `backend_keys.dart`) + rebuild.
   Empty URL keeps the dev-only offline bypass.

## Paystack wiring

1. Dashboard → Settings → API Keys & Webhooks → add webhook URL:
   `https://<deploy>/api/paystack-webhook`
2. Payment Pages: put `plan` (`monthly`/`yearly`) in the page metadata
   if you want per-plan keys; otherwise every successful charge mints a
   standard Pro key (amount/currency recorded on the key).
3. Test mode first: Paystack test payment → key row in Redis → email
   arrives → redeem in the app (see below).

## App redemption flow

Settings → Enter license key → app POSTs
`{key, deviceId}` to `<base>/api/redeem`:
- `200 ok` → Pro unlocks, stored locally per account, works offline.
- `200 recovered` → same device re-activating (backup restore).
- `404 unknown` → typo/forged key.
- `410 used` → key already redeemed on ANOTHER device.
- No network / no base URL → dev-only offline accept (debug builds).

`deviceId` is a random install UUID generated on-device (`DeviceStore`);
it is not hardware-bound and contains no personal data.

## Support operations (Upstash CLI / REST)

```sh
# look up a customer's keys
LRANGE qp:email:customer@example.com 0 -1
# inspect a key
HGETALL qp:key:QP-PRO-AB12-CD34
# re-issue after legit reinstall (clears the single-use mark)
HSET qp:key:QP-PRO-AB12-CD34 used 0 usedBy "" usedAt ""
# resend the key email (copy the key, send from Resend dashboard)
```

## Cost (all free tiers)

Vercel hobby (serverless) + Upstash Redis (10k cmds/day) + Resend
(100/day). Expected beta volume fits comfortably.
