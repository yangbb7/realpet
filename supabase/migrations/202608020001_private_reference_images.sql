-- RealPet reference images are persistent owner gallery objects. Keep this
-- bucket private and scope every object to the first path segment (auth.uid()).
-- Google Sign-In is the supported desktop identity provider. The policies use
-- auth.uid(), so they remain provider-agnostic within the authenticated role.

begin;

update storage.buckets
set public = false
where id = 'pet-reference-images';

drop policy if exists "RealPet anonymous owner inserts references" on storage.objects;
drop policy if exists "RealPet anonymous owner reads references" on storage.objects;
drop policy if exists "RealPet anonymous owner deletes references" on storage.objects;
drop policy if exists "RealPet owner inserts references" on storage.objects;
drop policy if exists "RealPet owner reads references" on storage.objects;
drop policy if exists "RealPet owner deletes references" on storage.objects;

create policy "RealPet owner inserts references"
on storage.objects
for insert
to authenticated
with check (
    bucket_id = 'pet-reference-images'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "RealPet owner reads references"
on storage.objects
for select
to authenticated
using (
    bucket_id = 'pet-reference-images'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "RealPet owner deletes references"
on storage.objects
for delete
to authenticated
using (
    bucket_id = 'pet-reference-images'
    and (storage.foldername(name))[1] = (select auth.uid()::text)
);

commit;
