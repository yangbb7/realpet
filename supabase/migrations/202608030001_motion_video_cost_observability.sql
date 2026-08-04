-- Keep provider accounting on the server. A NULL cost means the deployment
-- has not configured its contractual MiniMax rate; it never means free.

begin;

alter table public.realpet_motion_video_jobs
    add column if not exists provider_model text not null default 'MiniMax-H3',
    add column if not exists provider_cost_cents integer;

alter table public.realpet_motion_video_jobs
    drop constraint if exists realpet_motion_video_jobs_provider_cost_cents_check;

alter table public.realpet_motion_video_jobs
    add constraint realpet_motion_video_jobs_provider_cost_cents_check
    check (provider_cost_cents is null or provider_cost_cents >= 0);

commit;
