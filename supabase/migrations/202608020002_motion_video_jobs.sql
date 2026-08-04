-- Server-owned MiniMax job ledger. Desktop clients may read only their own
-- jobs through RLS; the Edge Function is the only writer and holds the
-- provider credential.

begin;

create table if not exists public.realpet_motion_video_jobs (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    pet_id uuid not null,
    action_kind text not null check (action_kind in (
        'head_follow', 'lie_down', 'paw', 'eat', 'cry', 'angry_stomp',
        'roll', 'stretch', 'sleep_snore', 'wave', 'jump_cheer', 'cuddle'
    )),
    duration_seconds smallint not null check (duration_seconds between 4 and 15),
    provider_task_id text unique,
    provider_status text not null default 'submitting' check (provider_status in (
        'submitting', 'queued', 'running', 'succeeded', 'failed', 'expired'
    )),
    error_message text,
    result_url text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

create index if not exists realpet_motion_video_jobs_owner_created_at_idx
    on public.realpet_motion_video_jobs (user_id, created_at desc);

create unique index if not exists realpet_motion_video_jobs_one_active_action_idx
    on public.realpet_motion_video_jobs (user_id, pet_id, action_kind)
    where provider_status in ('submitting', 'queued', 'running');

create or replace function public.realpet_touch_motion_video_job()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists realpet_touch_motion_video_job on public.realpet_motion_video_jobs;
create trigger realpet_touch_motion_video_job
before update on public.realpet_motion_video_jobs
for each row execute function public.realpet_touch_motion_video_job();

alter table public.realpet_motion_video_jobs enable row level security;

drop policy if exists "RealPet owners read motion video jobs" on public.realpet_motion_video_jobs;
create policy "RealPet owners read motion video jobs"
on public.realpet_motion_video_jobs
for select
to authenticated
using ((select auth.uid()) = user_id);

revoke all on public.realpet_motion_video_jobs from anon;
revoke insert, update, delete on public.realpet_motion_video_jobs from authenticated;
grant select on public.realpet_motion_video_jobs to authenticated;

commit;
