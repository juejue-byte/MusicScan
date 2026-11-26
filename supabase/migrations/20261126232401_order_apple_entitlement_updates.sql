-- Keep Apple signed transactions and notification retries from applying out of order.
-- This reuses the existing entitlements table and set_entitlement RPC.
alter table public.entitlements
  add column if not exists apple_signed_at timestamptz;

create function public.set_entitlement(
  p_user uuid,
  p_active boolean,
  p_product text,
  p_start timestamptz,
  p_end timestamptz,
  p_trial boolean,
  p_signed_at timestamptz
) returns void
language sql security definer set search_path = '' as $$
  insert into public.entitlements
    (user_id, active, product_id, period_start, period_end, is_trial, updated_at, apple_signed_at)
  values
    (p_user, p_active, p_product, p_start, p_end, p_trial, now(), coalesce(p_signed_at, now()))
  on conflict (user_id) do update set
    active = excluded.active,
    product_id = excluded.product_id,
    period_start = excluded.period_start,
    period_end = excluded.period_end,
    is_trial = excluded.is_trial,
    updated_at = now(),
    apple_signed_at = excluded.apple_signed_at
  where entitlements.apple_signed_at is null
     or excluded.apple_signed_at >= entitlements.apple_signed_at;
$$;

revoke execute on function public.set_entitlement(uuid, boolean, text, timestamptz, timestamptz, boolean, timestamptz)
  from public, anon, authenticated;
grant execute on function public.set_entitlement(uuid, boolean, text, timestamptz, timestamptz, boolean, timestamptz)
  to service_role;
