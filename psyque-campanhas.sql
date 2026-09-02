-- PSYQUE.INC — Campanhas + compartilhamento em tempo real
-- Execute no Supabase SQL Editor.
-- Este script usa ficha_id como TEXT de propósito, para funcionar tanto
-- se public.fichas.id for UUID quanto se for TEXT.

create extension if not exists pgcrypto;

create table if not exists public.campanhas (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  nome text not null check (char_length(trim(nome)) between 1 and 80),
  descricao text not null default '',
  codigo text not null unique check (codigo ~ '^[A-Z0-9]{8}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.campanha_membros (
  id uuid primary key default gen_random_uuid(),
  campanha_id uuid not null references public.campanhas(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  papel text not null default 'jogador' check (papel in ('mestre','jogador')),
  ficha_id text,
  created_at timestamptz not null default now(),
  unique(campanha_id,user_id)
);

create table if not exists public.ficha_compartilhamentos (
  id uuid primary key default gen_random_uuid(),
  ficha_id text not null,
  owner_id uuid not null references auth.users(id) on delete cascade,
  shared_with_user_id uuid references auth.users(id) on delete cascade,
  permissao text not null default 'editor' check (permissao in ('visualizador','editor')),
  codigo text not null unique check (codigo ~ '^[A-Z0-9]{8}$'),
  created_at timestamptz not null default now(),
  unique(ficha_id,shared_with_user_id)
);

create index if not exists idx_campanha_membros_user on public.campanha_membros(user_id);
create index if not exists idx_campanha_membros_campanha on public.campanha_membros(campanha_id);
create index if not exists idx_campanha_membros_ficha on public.campanha_membros(ficha_id);
create index if not exists idx_ficha_compartilhamentos_shared on public.ficha_compartilhamentos(shared_with_user_id);
create index if not exists idx_ficha_compartilhamentos_ficha on public.ficha_compartilhamentos(ficha_id);

-- updated_at automático
create or replace function public.psyque_set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_campanhas_updated_at on public.campanhas;
create trigger trg_campanhas_updated_at
before update on public.campanhas
for each row execute function public.psyque_set_updated_at();

-- Helper usado pelas policies sem recursão de RLS em campanha_membros.
create or replace function public.usuario_pode_ver_campanha(p_campanha_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.campanhas c
    where c.id=p_campanha_id and (c.owner_id=auth.uid() or exists(
      select 1 from public.campanha_membros m where m.campanha_id=c.id and m.user_id=auth.uid()
    ))
  );
$$;

revoke all on function public.usuario_pode_ver_campanha(uuid) from public;
grant execute on function public.usuario_pode_ver_campanha(uuid) to authenticated;

-- Gera um código curto sem depender de sequência.
create or replace function public.psyque_codigo8()
returns text
language sql
volatile
as $$
  select upper(substr(md5(random()::text || clock_timestamp()::text || gen_random_uuid()::text),1,8));
$$;

-- Criação de campanha: o criador já vira Mestre.
create or replace function public.criar_campanha(p_nome text, p_descricao text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_codigo text;
begin
  if auth.uid() is null then raise exception 'Você precisa estar logado.'; end if;
  if nullif(trim(p_nome),'') is null then raise exception 'Informe um nome para a campanha.'; end if;

  loop
    v_codigo := public.psyque_codigo8();
    begin
      insert into public.campanhas(owner_id,nome,descricao,codigo)
      values(auth.uid(),trim(p_nome),coalesce(trim(p_descricao),''),v_codigo)
      returning id into v_id;
      exit;
    exception when unique_violation then
      continue;
    end;
  end loop;

  insert into public.campanha_membros(campanha_id,user_id,papel)
  values(v_id,auth.uid(),'mestre')
  on conflict(campanha_id,user_id) do update set papel='mestre';

  return jsonb_build_object('id',v_id,'codigo',v_codigo);
end;
$$;

-- Entrada por código: não expõe a lista de campanhas para quem não participa.
create or replace function public.entrar_campanha_por_codigo(p_codigo text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'Você precisa estar logado.'; end if;
  select id into v_id from public.campanhas where codigo=upper(trim(p_codigo)) limit 1;
  if v_id is null then raise exception 'Código de campanha inválido.'; end if;

  insert into public.campanha_membros(campanha_id,user_id,papel)
  values(v_id,auth.uid(),'jogador')
  on conflict(campanha_id,user_id) do nothing;

  return v_id;
end;
$$;

-- Vincula a ficha do próprio jogador à campanha.
create or replace function public.adicionar_ficha_campanha(p_campanha_id uuid, p_ficha_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tipo text;
  v_titulo text;
begin
  if auth.uid() is null then raise exception 'Você precisa estar logado.'; end if;
  if not exists(select 1 from public.campanha_membros where campanha_id=p_campanha_id and user_id=auth.uid()) then
    raise exception 'Você não participa desta campanha.';
  end if;
  select tipo,titulo into v_tipo,v_titulo from public.fichas where id::text=p_ficha_id and user_id=auth.uid() limit 1;
  if v_tipo is null then raise exception 'A ficha não pertence à sua conta.'; end if;

  insert into public.campanha_membros(campanha_id,user_id,papel,ficha_id)
  values(p_campanha_id,auth.uid(),'jogador',p_ficha_id)
  on conflict(campanha_id,user_id) do update set ficha_id=excluded.ficha_id;

  return jsonb_build_object('ficha_id',p_ficha_id,'tipo',v_tipo,'titulo',v_titulo);
end;
$$;

-- Gera um código de compartilhamento para uma ficha que pertence ao usuário.
create or replace function public.gerar_codigo_compartilhamento_ficha(p_ficha_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_codigo text;
  v_id uuid;
  v_owner uuid;
begin
  if auth.uid() is null then raise exception 'Você precisa estar logado.'; end if;
  select user_id into v_owner from public.fichas where id::text=p_ficha_id limit 1;
  if v_owner is null or v_owner<>auth.uid() then raise exception 'Você não é o proprietário desta ficha.'; end if;

  loop
    v_codigo := public.psyque_codigo8();
    begin
      insert into public.ficha_compartilhamentos(ficha_id,owner_id,codigo,permissao)
      values(p_ficha_id,auth.uid(),v_codigo,'editor')
      returning id into v_id;
      exit;
    exception when unique_violation then
      continue;
    end;
  end loop;

  return jsonb_build_object('id',v_id,'codigo',v_codigo,'permissao','editor');
end;
$$;

-- A outra conta resgata o código e passa a ter acesso à ficha.
create or replace function public.entrar_ficha_por_codigo(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_share public.ficha_compartilhamentos%rowtype;
  v_tipo text;
begin
  if auth.uid() is null then raise exception 'Você precisa estar logado.'; end if;

  select * into v_share
  from public.ficha_compartilhamentos
  where codigo=upper(trim(p_codigo)) and shared_with_user_id is null
  limit 1;

  if v_share.id is null then raise exception 'Código de ficha inválido, expirado ou já utilizado.'; end if;
  if v_share.owner_id=auth.uid() then raise exception 'O proprietário não pode vincular a própria ficha.'; end if;

  update public.ficha_compartilhamentos
  set shared_with_user_id=auth.uid()
  where id=v_share.id and shared_with_user_id is null;

  select tipo into v_tipo from public.fichas where id::text=v_share.ficha_id limit 1;
  if v_tipo is null then raise exception 'A ficha não existe mais.'; end if;

  return jsonb_build_object('ficha_id',v_share.ficha_id,'tipo',v_tipo,'permissao',v_share.permissao);
end;
$$;

revoke all on function public.criar_campanha(text,text) from public;
grant execute on function public.criar_campanha(text,text) to authenticated;
revoke all on function public.entrar_campanha_por_codigo(text) from public;
grant execute on function public.entrar_campanha_por_codigo(text) to authenticated;
revoke all on function public.adicionar_ficha_campanha(uuid,text) from public;
grant execute on function public.adicionar_ficha_campanha(uuid,text) to authenticated;
revoke all on function public.gerar_codigo_compartilhamento_ficha(text) from public;
grant execute on function public.gerar_codigo_compartilhamento_ficha(text) to authenticated;
revoke all on function public.entrar_ficha_por_codigo(text) from public;
grant execute on function public.entrar_ficha_por_codigo(text) to authenticated;

-- RLS
alter table public.campanhas enable row level security;
alter table public.campanha_membros enable row level security;
alter table public.ficha_compartilhamentos enable row level security;

-- Campanhas
drop policy if exists psyque_campanhas_select on public.campanhas;
create policy psyque_campanhas_select on public.campanhas
for select to authenticated
using (public.usuario_pode_ver_campanha(id));

drop policy if exists psyque_campanhas_insert on public.campanhas;
create policy psyque_campanhas_insert on public.campanhas
for insert to authenticated with check(owner_id=auth.uid());

drop policy if exists psyque_campanhas_update on public.campanhas;
create policy psyque_campanhas_update on public.campanhas
for update to authenticated using(owner_id=auth.uid()) with check(owner_id=auth.uid());

drop policy if exists psyque_campanhas_delete on public.campanhas;
create policy psyque_campanhas_delete on public.campanhas
for delete to authenticated using(owner_id=auth.uid());

-- Membros
drop policy if exists psyque_membros_select on public.campanha_membros;
create policy psyque_membros_select on public.campanha_membros
for select to authenticated
using (public.usuario_pode_ver_campanha(campanha_id));

drop policy if exists psyque_membros_delete_self on public.campanha_membros;
create policy psyque_membros_delete_self on public.campanha_membros
for delete to authenticated using(user_id=auth.uid() or exists(select 1 from public.campanhas c where c.id=campanha_id and c.owner_id=auth.uid()));

-- Compartilhamentos
drop policy if exists psyque_share_select on public.ficha_compartilhamentos;
create policy psyque_share_select on public.ficha_compartilhamentos
for select to authenticated using(owner_id=auth.uid() or shared_with_user_id=auth.uid());

drop policy if exists psyque_share_insert on public.ficha_compartilhamentos;
create policy psyque_share_insert on public.ficha_compartilhamentos
for insert to authenticated with check(owner_id=auth.uid());

drop policy if exists psyque_share_delete on public.ficha_compartilhamentos;
create policy psyque_share_delete on public.ficha_compartilhamentos
for delete to authenticated using(owner_id=auth.uid() or shared_with_user_id=auth.uid());

-- Acesso às fichas compartilhadas.
drop policy if exists psyque_fichas_shared_select on public.fichas;
create policy psyque_fichas_shared_select on public.fichas
for select to authenticated
using (
  user_id=auth.uid()
  or exists(select 1 from public.ficha_compartilhamentos s where s.ficha_id=id::text and s.shared_with_user_id=auth.uid())
  or exists(select 1 from public.campanha_membros m where m.ficha_id=id::text and m.user_id=auth.uid())
  or exists(select 1 from public.campanha_membros m join public.campanhas c on c.id=m.campanha_id where m.ficha_id=id::text and c.owner_id=auth.uid())
);

-- Edição por proprietário ou por quem recebeu permissão de editor.
drop policy if exists psyque_fichas_shared_update on public.fichas;
create policy psyque_fichas_shared_update on public.fichas
for update to authenticated
using (
  user_id=auth.uid()
  or exists(select 1 from public.ficha_compartilhamentos s where s.ficha_id=id::text and s.shared_with_user_id=auth.uid() and s.permissao='editor')
  or exists(select 1 from public.campanha_membros m where m.ficha_id=id::text and m.user_id=auth.uid())
  or exists(select 1 from public.campanha_membros m join public.campanhas c on c.id=m.campanha_id where m.ficha_id=id::text and c.owner_id=auth.uid())
)
;

-- Realtime: adiciona as tabelas à publicação somente se ainda não estiverem nela.
do $$
begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='fichas') then
    alter publication supabase_realtime add table public.fichas;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='campanha_membros') then
    alter publication supabase_realtime add table public.campanha_membros;
  end if;
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='campanhas') then
    alter publication supabase_realtime add table public.campanhas;
  end if;
end $$;

-- Para o Realtime respeitar RLS, as tabelas precisam ser legíveis pelo assinante.
-- Não coloque service_role no index.html.
