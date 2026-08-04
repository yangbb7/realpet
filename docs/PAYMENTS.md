# RealPet Payments and Cost Observability

## Current Boundary

New action videos use MiniMax H3 only. The macOS app sends an authenticated
Supabase user session, pet ID, action kind, and duration to
`minimax-video`; it never receives or stores a provider key. The Edge Function
is the only component allowed to read private gallery images, create provider
tasks, or update `realpet_motion_video_jobs`.

Each job stores the provider model and, after success, an optional
`provider_cost_cents`. Set `MINIMAX_COST_CENTS_PER_SECOND` in Supabase Edge
Function secrets to the contracted rate. A missing value remains `NULL` and is
reported as unknown in the local runtime metrics; it must not be interpreted as
zero cost.

```bash
supabase secrets set MINIMAX_API_KEY=your_minimax_api_key
supabase secrets set MINIMAX_COST_CENTS_PER_SECOND=your_contracted_rate
supabase functions deploy minimax-video
```

Apply both motion-job migrations before deployment:

```text
202608020002_motion_video_jobs.sql
202608030001_motion_video_cost_observability.sql
```

## Metrics

The desktop app writes privacy-preserving JSONL events at
`~/Library/Application Support/RealPet/runtime-metrics.jsonl`. Events contain
only timing, byte counts, pipeline outcome, identity-validation outcome, action
kind, duration, and the server-provided provider cost. They never contain image
data, prompts, account IDs, or access tokens.

Track these before changing price or quality defaults:

- `app.startup`: launch timing and maximum resident bytes.
- `storage.footprint`: Application Support and bundle-resource disk usage.
- `cloud_gallery.sync` and `pipeline.preparation`: phase timings and outcome.
- `identity_validation`: pass/fail ratio.
- `provider.minimax_video`: successful action duration and provider cost.

## Future Billing

Stripe Checkout and any entitlement ledger remain future work. When added,
reserve an entitlement atomically before MiniMax submission, consume it only
after provider acceptance, and release it only on a confirmed non-chargeable
failure. The Edge Function, not desktop state, must make every permit/deny
decision.
