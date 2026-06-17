-- Public profiles table — one row per user, auto-created on signup.
-- Dashboard reads aggregate stats from here instead of auth.users.

CREATE TABLE IF NOT EXISTS profiles (
  id             UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at   TIMESTAMPTZ,
  country        TEXT,
  app_version    TEXT
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Each user can read and update only their own profile.
CREATE POLICY "profiles_select_own"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "profiles_update_own"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

-- ── Auto-create profile on signup ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION create_profile_on_signup()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, created_at)
  VALUES (NEW.id, NEW.created_at)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- Add columns that 0001_init.sql didn't include (CREATE TABLE IF NOT EXISTS above is a no-op).
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS last_seen_at TIMESTAMPTZ;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS app_version  TEXT;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION create_profile_on_signup();

-- Backfill existing users (idempotent).
INSERT INTO profiles (id, created_at)
SELECT id, created_at FROM auth.users
ON CONFLICT (id) DO NOTHING;

-- ── Aggregate stats RPC ───────────────────────────────────────────────────────
-- Returns anonymous aggregate counts only — no individual user data exposed.
-- SECURITY DEFINER lets any authenticated caller get the totals without
-- needing direct SELECT on profiles.

CREATE OR REPLACE FUNCTION get_user_stats()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total',          COUNT(*),
    'new_this_month', COUNT(*) FILTER (
                        WHERE created_at >= date_trunc('month', now())
                      ),
    'active_7d',      COUNT(*) FILTER (
                        WHERE last_seen_at >= now() - INTERVAL '7 days'
                      ),
    'daily_signups',  (
      SELECT json_agg(row_data ORDER BY day ASC)
      FROM (
        SELECT
          to_char(d.day, 'DD Mon') AS label,
          d.day,
          COUNT(p.id)              AS count
        FROM generate_series(
          date_trunc('day', now()) - INTERVAL '6 days',
          date_trunc('day', now()),
          INTERVAL '1 day'
        ) AS d(day)
        LEFT JOIN profiles p
          ON date_trunc('day', p.created_at AT TIME ZONE 'UTC') = d.day
        GROUP BY d.day
        ORDER BY d.day
      ) row_data
    )
  )
  INTO result
  FROM profiles;

  RETURN result;
END;
$$;

-- Only authenticated users can call this function.
REVOKE ALL ON FUNCTION get_user_stats() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_user_stats() TO authenticated;
