# RealPet Supabase Storage

The app bundles only the Supabase project URL, bucket name, and Publishable
Key. Google login is mandatory before the console opens. The app uses the
resulting Supabase JWT for Storage. Reference images are uploaded when the
owner adds them to 图片管理, then remain in that owner's cloud gallery below:

```text
<google-user-id>/<pet-id>/references/<reference-id>.<extension>
```

Before release, apply [202608020001_private_reference_images.sql](migrations/202608020001_private_reference_images.sql). The migration makes `pet-reference-images` private and limits insert, read, signing, and deletion to each authenticated user's own first-level directory.

## Google sign-in setup

1. In Google Cloud, create a **Web application** OAuth client. Its authorized
   redirect URI must be `https://opgmbtrhxrqdofbgpdbp.supabase.co/auth/v1/callback`.
2. In Supabase Dashboard, open **Authentication → Providers → Google**, enable
   it, and enter that Google client ID and client secret. The client secret
   stays in Supabase and must never be bundled in RealPet.
3. In **Authentication → URL Configuration**, add
   `realpet-auth://auth/callback` to the Redirect URLs allow list.

RealPet opens the system browser with Supabase's OAuth endpoint, receives the
callback through that custom scheme, validates the returned Supabase user, and
keeps only a revocable session file in Application Support with mode `0600`.
The local video/action catalog is keyed by this Google user. Videos, extracted
frames, and desktop runtime assets remain local; original photos are cloud
gallery objects. The MiniMax Edge Function creates short-lived URLs for up to
four gallery photos in memory and never writes a new reference image.

Do not put a `service_role` key in the app or in an RLS policy. The Publishable
Key is intentionally bundled at packaging time through
`REALPET_SUPABASE_PUBLISHABLE_KEY`; it is not a per-user setting and is never
read from Keychain. Configure Google OAuth consent-screen branding and Supabase
Auth rate limits before distributing the app broadly.

## MiniMax H3 Edge Function

`functions/minimax-video/index.ts` is the only process that calls MiniMax H3.
The desktop client supplies a Supabase user JWT, a pet ID, an action kind, and a
duration. The function lists that user's private gallery, creates short-lived
signed URLs for up to four photos, and submits the fixed RealPet action prompt
to MiniMax. `MINIMAX_API_KEY` stays in Supabase Edge Function Secrets and must
not be placed in the macOS bundle or in a client request.

1. Apply [202608020002_motion_video_jobs.sql](migrations/202608020002_motion_video_jobs.sql)
   and [202608030001_motion_video_cost_observability.sql](migrations/202608030001_motion_video_cost_observability.sql)
   in the Supabase SQL editor. It creates the owner-scoped job ledger used to
   prevent duplicate action submissions.
2. Install and authenticate the Supabase CLI, then link this project:

   ```bash
   brew install supabase/tap/supabase
   supabase login
   supabase link --project-ref opgmbtrhxrqdofbgpdbp
   ```

3. Set the provider key as a server secret. Do not commit it to an `.env` file:

   ```bash
   supabase secrets set MINIMAX_API_KEY=your_minimax_api_key
   supabase secrets set MINIMAX_COST_CENTS_PER_SECOND=your_contracted_rate
   ```

4. Deploy the function:

   ```bash
   supabase functions deploy minimax-video
   ```

`supabase/config.toml` keeps `verify_jwt = true`: invocations must send the
current user session in `Authorization: Bearer <access-token>` and the bundled
Supabase Publishable Key in `apikey`. A `create` request returns a RealPet job
ID immediately; a `status` request returns the latest provider status and a
download URL only after that same owner’s job succeeds.
