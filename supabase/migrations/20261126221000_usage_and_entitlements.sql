-- MusicScan: who may read how many pages. Clients can only read their own rows; all writes go through the
-- server (service role) via claim_page / unlock_page, or the RevenueCat webhook via set_entitlement.
-- Applied to the Supabase project "musicscan" (fliegieshsoywgrjyltw) on 2026-11-26.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  free_page_used_at timestamptz
);

create table public.entitlements (
  user_id uuid primary key references auth.users (id) on delete cascade,
  active boolean not null default false,
  product_id text,
  period_start timestamptz,
  period_end timestamptz,
  is_trial boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.page_usage (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  job_id text not null,
  kind text not null check (kind in ('free', 'pro', 'preview')),
  period_start timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, job_id)
);
create index page_usage_user_period on public.page_usage (user_id, period_start) where kind = 'pro';

alter table public.profiles enable row level security;
alter table public.entitlements enable row level security;
alter table public.page_usage enable row level security;
create policy "read own profile" on public.profiles for select to authenticated using ((select auth.uid()) = id);
create policy "read own entitlement" on public.entitlements for select to authenticated using ((select auth.uid()) = user_id);
create policy "read own usage" on public.page_usage for select to authenticated using ((select auth.uid()) = user_id);

-- every new account (anonymous included) gets a profile
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Decide what one scanned page gets: 'full' (Pro, under the cap), 'free' (the one free page), 'preview' (half page)
-- or 'cap' (Pro, cap reached; nothing recorded). Idempotent per job.
create function public.claim_page(p_user uuid, p_job text, p_limit int default 30)
returns table (access text, pages_used int, page_limit int, renews_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  prof public.profiles;
  ent public.entitlements;
  used int;
  prior text;
begin
  insert into public.profiles (id) values (p_user) on conflict do nothing;
  select * into prof from public.profiles where id = p_user for update;
  select * into ent from public.entitlements where user_id = p_user;
  select kind into prior from public.page_usage where user_id = p_user and job_id = p_job;
  if ent.active and (ent.period_end is null or ent.period_end > now()) then
    select count(*) into used from public.page_usage
      where user_id = p_user and kind = 'pro' and period_start is not distinct from ent.period_start;
    if prior is not null then
      return query select case when prior = 'preview' then 'preview' else 'full' end, used, p_limit, ent.period_end;
      return;
    end if;
    if used >= p_limit then
      return query select 'cap'::text, used, p_limit, ent.period_end;
      return;
    end if;
    insert into public.page_usage (user_id, job_id, kind, period_start) values (p_user, p_job, 'pro', ent.period_start);
    return query select 'full'::text, used + 1, p_limit, ent.period_end;
    return;
  end if;
  if prior is not null then
    return query select case when prior = 'preview' then 'preview' else 'free' end, 0, p_limit, null::timestamptz;
    return;
  end if;
  if prof.free_page_used_at is null then
    update public.profiles set free_page_used_at = now() where id = p_user;
    insert into public.page_usage (user_id, job_id, kind) values (p_user, p_job, 'free');
    return query select 'free'::text, 0, p_limit, null::timestamptz;
    return;
  end if;
  insert into public.page_usage (user_id, job_id, kind) values (p_user, p_job, 'preview');
  return query select 'preview'::text, 0, p_limit, null::timestamptz;
end $$;

-- After a purchase: turn a preview into a Pro page (counts toward the cap). Returns the new access.
create function public.unlock_page(p_user uuid, p_job text, p_limit int default 30)
returns table (access text, pages_used int, page_limit int, renews_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  ent public.entitlements;
  used int;
  prior text;
begin
  select * into ent from public.entitlements where user_id = p_user;
  select kind into prior from public.page_usage where user_id = p_user and job_id = p_job for update;
  if not coalesce(ent.active, false) or (ent.period_end is not null and ent.period_end <= now()) then
    return query select 'preview'::text, 0, p_limit, null::timestamptz;
    return;
  end if;
  select count(*) into used from public.page_usage
    where user_id = p_user and kind = 'pro' and period_start is not distinct from ent.period_start;
  if prior is distinct from 'preview' then
    return query select 'full'::text, used, p_limit, ent.period_end;
    return;
  end if;
  if used >= p_limit then
    return query select 'cap'::text, used, p_limit, ent.period_end;
    return;
  end if;
  update public.page_usage set kind = 'pro', period_start = ent.period_start
    where user_id = p_user and job_id = p_job;
  return query select 'full'::text, used + 1, p_limit, ent.period_end;
end $$;

-- Called by the RevenueCat webhook (an Edge Function with the service role).
create function public.set_entitlement(p_user uuid, p_active boolean, p_product text, p_start timestamptz,
                                       p_end timestamptz, p_trial boolean)
returns void language sql security definer set search_path = '' as $$
  insert into public.entitlements (user_id, active, product_id, period_start, period_end, is_trial, updated_at)
  values (p_user, p_active, p_product, p_start, p_end, p_trial, now())
  on conflict (user_id) do update set active = excluded.active, product_id = excluded.product_id,
    period_start = excluded.period_start, period_end = excluded.period_end, is_trial = excluded.is_trial,
    updated_at = now();
$$;

revoke execute on function public.claim_page(uuid, text, int) from public, anon, authenticated;
revoke execute on function public.unlock_page(uuid, text, int) from public, anon, authenticated;
revoke execute on function public.set_entitlement(uuid, boolean, text, timestamptz, timestamptz, boolean) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.claim_page(uuid, text, int) to service_role;
grant execute on function public.unlock_page(uuid, text, int) to service_role;
grant execute on function public.set_entitlement(uuid, boolean, text, timestamptz, timestamptz, boolean) to service_role;
