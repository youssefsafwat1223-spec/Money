# Mali Supabase Backend

This backend follows Architecture Path A: financial data stays on device. Supabase stores only auth identity, encrypted backup metadata/blob, anonymous metrics, and read-only parsing rules.

## Run The Migration

Option 1: Open the Supabase SQL editor and run `supabase/migrations/0001_init.sql`.

Option 2: With the Supabase CLI linked to your project:

```bash
supabase db push
```

## Required Dashboard Steps

1. Create the Supabase project in a Gulf-near region where possible for PDPL-aware deployment.
2. Enable Google and Apple auth providers in Authentication > Providers.
3. Create a private Storage bucket named `backups`.
4. Keep the anon key public only via runtime `--dart-define`; never hardcode keys in source.

## Flutter Runtime Config

Run the app with:

```bash
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

Without these defines the app intentionally falls back to local stub auth/backup so tests and local development work offline.
