-- S3: custom category sync joins the shared planning engine. The push uses
-- upsert(on_conflict = user_id,local_id), so ensure that uniqueness exists on
-- the pre-existing user_categories table. Idempotent + safe.

create unique index if not exists uidx_user_categories_owner_local
  on user_categories(user_id, local_id);
