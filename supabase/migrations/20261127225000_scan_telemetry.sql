-- MusicScan: per-scan latency, quality, and OMR regression telemetry.
-- Saved automatically by the iOS app (`ScanSLIRecorder`) and server so we can track
-- wall-clock time, GPU OMR inference seconds, on-device preparation latency, and
-- scan quality scores across versions without cluttering the user-facing editor UI.

create table if not exists public.scan_telemetry (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  job_id text not null,
  title text,
  page_number int not null default 1,
  total_pages int not null default 1,
  on_device_prep_ms int not null default 0,
  wall_seconds double precision not null,
  omr_seconds double precision,
  overhead_seconds double precision,
  measures_count int not null default 0,
  quality_score int,
  quality_level text,
  flagged_bars_count int,
  red_bars_count int,
  fast_mode boolean not null default false,
  access_mode text not null default 'full',
  app_version text,
  device_model text,
  created_at timestamptz not null default now(),
  unique (user_id, job_id)
);

create index if not exists scan_telemetry_created_at_idx on public.scan_telemetry (created_at desc);
create index if not exists scan_telemetry_user_idx on public.scan_telemetry (user_id, created_at desc);

alter table public.scan_telemetry enable row level security;

create policy "insert own scan telemetry"
  on public.scan_telemetry
  for insert
  to authenticated
  with check ((select auth.uid()) = user_id);

create policy "update own scan telemetry"
  on public.scan_telemetry
  for update
  to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create policy "read own scan telemetry"
  on public.scan_telemetry
  for select
  to authenticated
  using ((select auth.uid()) = user_id);
