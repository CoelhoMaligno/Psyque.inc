-- PSYQUE.INC — BANCO ONLINE COM LOGIN POR USUÁRIO
-- Execute no Supabase: SQL Editor -> New query -> Run

create table if not exists public.registros (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  tipo text not null check (tipo in ('paciente','ameaca','item')),
  titulo text not null default 'Sem título',
  dados jsonb not null default '{}'::jsonb,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists registros_user_id_idx
on public.registros(user_id);

create index if not exists registros_user_tipo_idx
on public.registros(user_id,tipo);

alter table public.registros enable row level security;

drop policy if exists "usuarios veem os proprios registros" on public.registros;
drop policy if exists "usuarios criam os proprios registros" on public.registros;
drop policy if exists "usuarios atualizam os proprios registros" on public.registros;
drop policy if exists "usuarios excluem os proprios registros" on public.registros;

create policy "usuarios veem os proprios registros"
on public.registros for select
to authenticated
using (auth.uid() = user_id);

create policy "usuarios criam os proprios registros"
on public.registros for insert
to authenticated
with check (auth.uid() = user_id);

create policy "usuarios atualizam os proprios registros"
on public.registros for update
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

create policy "usuarios excluem os proprios registros"
on public.registros for delete
to authenticated
using (auth.uid() = user_id);

grant select,insert,update,delete on public.registros to authenticated;
