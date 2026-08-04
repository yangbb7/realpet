# ADR-0007: Stripe Checkout With Server-Authoritative Action Entitlements

## Status

Proposed

## Context

RealPet generates one provider video for one selected pet action. A provider
request has a non-zero, asynchronous, potentially irreversible cost. The
macOS app currently has a Google/Supabase session and a MiniMax Edge Function,
but no payment, entitlement, refund, or dispute model. Provider access must
remain behind that server boundary.

The business wants to use Stripe only. It needs one-time action packs and
monthly included actions while avoiding duplicate charges when a user double
clicks, uses two Macs, loses network connectivity, or Stripe retries a
webhook.

## Decision

Use Stripe Hosted Checkout for payment collection and Stripe Customer Portal
for self-service subscription management. The app opens browser URLs returned
by authenticated Supabase Edge Functions and never handles card data or Stripe
secret keys.

Use Supabase Postgres as the authoritative immutable entitlement ledger. Stripe
webhooks, verified from their raw body and signing secret, are the only source
that grants paid entitlements. An authenticated `billing-state` endpoint is the
only state used by the app to display availability. A user cannot write orders,
balances, grants, reservations, or provider costs through RLS.

The MiniMax generation path must call a transactionally protected reservation
RPC before a provider request. It consumes a reservation once the
provider accepts a task and release it only on a clear non-chargeable failure.
Uncertain submissions remain reconciling to avoid duplicate provider work.

## Consequences

### Positive

- Stripe owns PCI-sensitive checkout, 3DS, payment methods, receipts, and
  customer billing details.
- The server, not a mutable desktop preference, makes the final paid/unpaid
  generation decision.
- Stripe webhook retries and concurrent app actions are idempotent and
  auditable.
- The same entitlement contract protects present and future video providers.
- Refunds, disputes, retry compensation, revenue and COGS can be reconciled.

### Negative

- Checkout leaves the app for a browser and requires an internet connection.
- The product must run and monitor several Edge Functions, RLS policies and
  a daily reconciliation job.
- No provider key may be introduced into a desktop release build.
- This Stripe-only purchase surface is suitable for direct distribution, not a
  generic Mac App Store submission that unlocks digital features.

### Neutral

- Stripe Price IDs are server configuration, not application constants.
- Purchased “actions” are a restricted service entitlement, not cash balance
  or transferable stored value.

## Alternatives Considered

**Client-side Stripe PaymentIntents and local credit counter**

Rejected. A modified app could choose its own price, skip a debit, replay a
result, or use the model key directly.

**Stripe Payment Links only**

Rejected for the primary flow. Links are useful for marketing, but do not bind
an order to the authenticated RealPet user before Checkout or provide an
atomic entitlement reservation protocol.

**Stripe Billing Meters/Credits as the live action balance**

Rejected for MVP. Meter events and credit burn-down are billing lifecycle
mechanisms; RealPet must make an immediate, concurrent-safe permit/deny
decision before starting a paid model task. Stripe remains the payment system;
Postgres is the entitlement system of record.

**Keep a provider direct because its current key is free**

Rejected. A bundled key can be extracted and it lets a client use a paid
product without a server-authoritative entitlement check.

## References

- <https://docs.stripe.com/payments/checkout/how-checkout-works>
- <https://docs.stripe.com/customer-management>
- <https://supabase.com/docs/guides/functions/auth>
- [RealPet 支付方案](../PAYMENTS.md)
