-- The provider precision is server-owned and auditable. Existing H3 jobs used
-- the same native 2K output before this column was introduced.

begin;

alter table public.realpet_motion_video_jobs
    add column if not exists provider_resolution text not null default '2K';

alter table public.realpet_motion_video_jobs
    drop constraint if exists realpet_motion_video_jobs_provider_resolution_check;

alter table public.realpet_motion_video_jobs
    add constraint realpet_motion_video_jobs_provider_resolution_check
    check (provider_resolution = '2K');

commit;
