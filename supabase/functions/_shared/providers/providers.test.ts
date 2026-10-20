import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { SandboxProvider } from "./sandbox.ts";
import { getProvider } from "./index.ts";
import { WebhookSignatureError } from "./types.ts";
import { safeEqual } from "../crypto.ts";
import { buildMessage } from "../fcm.ts";

const secret = "test-secret";
const body = JSON.stringify({ id: "evt_1", type: "payment.succeeded", providerRef: "sbx_1", amountMinor: 15750, currency: "aed" });

Deno.test("sandbox: valid signature yields normalised, non-live event", async () => {
  const p = new SandboxProvider(secret);
  const sig = await SandboxProvider.sign(secret, body);
  const e = await p.parseWebhook(body, new Headers({ "x-sandbox-signature": sig }));
  assertEquals(e?.eventId, "evt_1"); assertEquals(e?.currency, "AED"); assertEquals(e?.livemode, false); assert(p.isSandbox);
});

Deno.test("sandbox: tampered body, wrong secret, stale timestamp and missing header are rejected", async () => {
  const p = new SandboxProvider(secret);
  const sig = await SandboxProvider.sign(secret, body);
  await assertRejects(() => p.parseWebhook(body.replace("15750", "1"), new Headers({ "x-sandbox-signature": sig })), WebhookSignatureError);
  const wrong = await SandboxProvider.sign("other", body), stale = await SandboxProvider.sign(secret, body, 1000);
  await assertRejects(() => p.parseWebhook(body, new Headers({ "x-sandbox-signature": wrong })), WebhookSignatureError);
  await assertRejects(() => p.parseWebhook(body, new Headers({ "x-sandbox-signature": stale })), WebhookSignatureError);
  await assertRejects(() => p.parseWebhook(body, new Headers()), WebhookSignatureError);
});

Deno.test("provider selection: sandbox needs a secret; live Stripe keys refused without explicit approval", () => {
  const env = (m: Record<string, string>) => (k: string) => m[k];
  assertEquals(getProvider(env({ SANDBOX_WEBHOOK_SECRET: "x" })).name, "sandbox");
  try { getProvider(env({})); throw new Error("should fail"); } catch (e) { assert((e as Error).message.includes("SANDBOX_WEBHOOK_SECRET")); }
  try {
    getProvider(env({ PAYMENT_PROVIDER: "stripe", STRIPE_SECRET_KEY: "sk_live_abc", STRIPE_WEBHOOK_SECRET: "whsec_x" }));
    throw new Error("should fail");
  } catch (e) { assert((e as Error).message.includes("live Stripe key refused")); }
  assertEquals(getProvider(env({ PAYMENT_PROVIDER: "stripe", STRIPE_SECRET_KEY: "sk_test_abc", STRIPE_WEBHOOK_SECRET: "whsec_x" })).name, "stripe");
});

Deno.test("stripe: rejects webhooks with a bad signature", async () => {
  const p = getProvider((k) => ({ PAYMENT_PROVIDER: "stripe", STRIPE_SECRET_KEY: "sk_test_abc", STRIPE_WEBHOOK_SECRET: "whsec_x" } as Record<string, string>)[k]);
  await assertRejects(() => p.parseWebhook("{}", new Headers({ "stripe-signature": "t=1,v1=bad" })), WebhookSignatureError);
});

Deno.test("safeEqual", () => { assert(safeEqual("abc", "abc")); assert(!safeEqual("abc", "abd")); assert(!safeEqual("abc", "abcd")); });

Deno.test("fcm message data values are strings", () => {
  const m = buildMessage("tok", { title: "t", body: "b", data: { booking_id: 5, ok: true } });
  assertEquals(m.message.data, { booking_id: "5", ok: "true" });
});
