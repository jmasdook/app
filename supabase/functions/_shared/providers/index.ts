import { PaymentProvider } from "./types.ts";
import { SandboxProvider } from "./sandbox.ts";
import { StripeProvider } from "./stripe.ts";

export function getProvider(env: (k: string) => string | undefined = Deno.env.get.bind(Deno.env)): PaymentProvider {
  const name = env("PAYMENT_PROVIDER") ?? "sandbox";
  if (name === "sandbox") {
    const secret = env("SANDBOX_WEBHOOK_SECRET");
    if (!secret) throw new Error("SANDBOX_WEBHOOK_SECRET is not configured");
    return new SandboxProvider(secret);
  }
  if (name === "stripe") {
    const key = env("STRIPE_SECRET_KEY"), wh = env("STRIPE_WEBHOOK_SECRET");
    if (!key || !wh) throw new Error("STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET are not configured");
    if (key.startsWith("sk_live_") && env("ALLOW_LIVE_PAYMENTS") !== "true") {
      throw new Error("live Stripe key refused: set ALLOW_LIVE_PAYMENTS=true only after documented launch approval");
    }
    return new StripeProvider(key, wh);
  }
  throw new Error(`unknown PAYMENT_PROVIDER ${name}`);
}
