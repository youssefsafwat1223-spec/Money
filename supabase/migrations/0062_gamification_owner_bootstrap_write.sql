-- The Flutter gamification sync performs a one-time local bootstrap for a
-- signed-in user before switching to server-authoritative pulls. Migration
-- 0056 only granted SELECT, so fresh users could never create their initial
-- XP/streak/achievement rows. Keep writes owner-scoped; service_role behavior
-- is unchanged and cross-user writes remain impossible.

drop policy if exists user_xp_levels_owner_insert on public.user_xp_levels;
create policy user_xp_levels_owner_insert on public.user_xp_levels
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists user_xp_levels_owner_update on public.user_xp_levels;
create policy user_xp_levels_owner_update on public.user_xp_levels
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists user_streaks_owner_insert on public.user_streaks;
create policy user_streaks_owner_insert on public.user_streaks
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists user_streaks_owner_update on public.user_streaks;
create policy user_streaks_owner_update on public.user_streaks
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists user_achievements_owner_insert on public.user_achievements;
create policy user_achievements_owner_insert on public.user_achievements
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists user_achievements_owner_update on public.user_achievements;
create policy user_achievements_owner_update on public.user_achievements
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
