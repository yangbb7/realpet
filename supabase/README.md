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
gallery objects. Agnes receives a short-lived signed URL for the first gallery
photo, while MiniMax receives gallery bytes in memory. Neither provider path
uploads a reference image during video generation.

Do not put a `service_role` key in the app or in an RLS policy. The Publishable
Key is intentionally bundled at packaging time through
`REALPET_SUPABASE_PUBLISHABLE_KEY`; it is not a per-user setting and is never
read from Keychain. Configure Google OAuth consent-screen branding and Supabase
Auth rate limits before distributing the app broadly.
