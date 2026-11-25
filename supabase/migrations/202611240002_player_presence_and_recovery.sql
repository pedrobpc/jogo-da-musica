-- Recent player connection status and administrator-issued one-time recovery codes.
begin;

create table if not exists public.player_presence (
  player_id uuid primary key references public.players(id) on delete cascade,
  last_seen_at timestamptz not null default now()
);

create table if not exists public.player_recovery_codes (
  player_id uuid primary key references public.players(id) on delete cascade,
  game_id uuid not null references public.games(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  used_at timestamptz
);

create index if not exists player_recovery_codes_game_id_idx
  on public.player_recovery_codes(game_id);

alter table public.player_presence enable row level security;
alter table public.player_recovery_codes enable row level security;
revoke all on table public.player_presence, public.player_recovery_codes from anon, authenticated;
revoke all on table public.player_presence, public.player_recovery_codes from public;

create or replace function public.player_heartbeat(
  p_player_id uuid,
  p_session_token text
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_game_id uuid;
  v_game_hash text;
  v_legacy_hash text;
begin
  if p_player_id is null or length(coalesce(p_session_token, '')) < 12 then
    raise exception 'Sessão inválida';
  end if;

  select p.game_id into v_game_id
  from public.players p
  where p.id = p_player_id;

  if v_game_id is null then
    raise exception 'Jogador não encontrado';
  end if;

  v_game_hash := public.hash_session_token(
    p_session_token || ':' || v_game_id::text
  );
  v_legacy_hash := public.hash_session_token(p_session_token);

  if not exists (
    select 1
    from public.player_sessions ps
    where ps.player_id = p_player_id
      and ps.session_token_hash in (v_game_hash, v_legacy_hash)
  ) then
    raise exception 'Esta sessão foi substituída ou expirou. Use um código de retorno do administrador.';
  end if;

  insert into public.player_presence(player_id, last_seen_at)
  values (p_player_id, clock_timestamp())
  on conflict (player_id) do update
    set last_seen_at = excluded.last_seen_at;

  return true;
end;
$function$;

create or replace function public.admin_player_connections(
  p_game_id uuid,
  p_password text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'player_id', p.id,
      'name', p.name,
      'avatar_emoji', p.avatar_emoji,
      'last_seen_at', pp.last_seen_at,
      'is_online', coalesce(pp.last_seen_at >= now() - interval '45 seconds', false),
      'connection_status', case
        when pp.last_seen_at is null then 'never_seen'
        when pp.last_seen_at >= now() - interval '45 seconds' then 'online'
        else 'offline'
      end
    ) order by p.joined_at, p.name
  ), '[]'::jsonb)
  into v_result
  from public.players p
  left join public.player_presence pp on pp.player_id = p.id
  where p.game_id = p_game_id;

  return v_result;
end;
$function$;

create or replace function public.admin_issue_player_recovery_code(
  p_game_id uuid,
  p_password text,
  p_player_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_code text;
  v_expires_at timestamptz := now() + interval '10 minutes';
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if not exists (
    select 1 from public.players p
    where p.id = p_player_id and p.game_id = p_game_id
  ) then
    raise exception 'Jogador não encontrado nesta partida';
  end if;

  -- Twelve hexadecimal characters are easy to read aloud and hard to guess.
  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

  insert into public.player_recovery_codes(
    player_id, game_id, code_hash, expires_at, created_at, used_at
  )
  values (
    p_player_id,
    p_game_id,
    public.hash_session_token('recovery:' || p_game_id::text || ':' || v_code),
    v_expires_at,
    now(),
    null
  )
  on conflict (player_id) do update
    set game_id = excluded.game_id,
        code_hash = excluded.code_hash,
        expires_at = excluded.expires_at,
        created_at = excluded.created_at,
        used_at = null;

  return jsonb_build_object(
    'recovery_code', v_code,
    'expires_at', v_expires_at
  );
end;
$function$;

create or replace function public.claim_player_session(
  p_game_code text,
  p_recovery_code text,
  p_session_token text
)
returns table(
  result_game_id uuid,
  result_game_code text,
  result_player_id uuid,
  result_player_name text,
  result_avatar_emoji text
)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_game_id uuid;
  v_game_code text;
  v_player_id uuid;
  v_code text;
  v_hash text;
begin
  v_code := upper(regexp_replace(coalesce(p_recovery_code, ''), '\s', '', 'g'));

  if length(coalesce(p_session_token, '')) < 12 then
    raise exception 'Sessão inválida';
  end if;

  if v_code !~ '^[0-9A-F]{12}$' then
    raise exception 'Confira o código de retorno e tente novamente';
  end if;

  select g.id, g.code into v_game_id, v_game_code
  from public.games g
  where upper(g.code) = upper(trim(coalesce(p_game_code, '')));

  if v_game_id is null then
    raise exception 'Sala não encontrada';
  end if;

  v_hash := public.hash_session_token(
    'recovery:' || v_game_id::text || ':' || v_code
  );

  select rc.player_id into v_player_id
  from public.player_recovery_codes rc
  join public.players p on p.id = rc.player_id and p.game_id = v_game_id
  where rc.game_id = v_game_id
    and rc.code_hash = v_hash
    and rc.expires_at > now()
    and rc.used_at is null
  for update of rc;

  if v_player_id is null then
    raise exception 'Código inválido, vencido ou já utilizado. Peça um novo código ao administrador.';
  end if;

  update public.player_recovery_codes
  set used_at = now()
  where player_id = v_player_id;

  insert into public.player_sessions(player_id, session_token_hash)
  values (
    v_player_id,
    public.hash_session_token(p_session_token || ':' || v_game_id::text)
  )
  on conflict (player_id) do update
    set session_token_hash = excluded.session_token_hash;

  insert into public.player_presence(player_id, last_seen_at)
  values (v_player_id, clock_timestamp())
  on conflict (player_id) do update
    set last_seen_at = excluded.last_seen_at;

  return query
  select v_game_id, v_game_code, p.id, p.name, p.avatar_emoji
  from public.players p
  where p.id = v_player_id;
end;
$function$;

revoke all on function public.player_heartbeat(uuid, text) from public;
revoke all on function public.admin_player_connections(uuid, text) from public;
revoke all on function public.admin_issue_player_recovery_code(uuid, text, uuid) from public;
revoke all on function public.claim_player_session(text, text, text) from public;
grant execute on function public.player_heartbeat(uuid, text) to anon, authenticated;
grant execute on function public.admin_player_connections(uuid, text) to anon, authenticated;
grant execute on function public.admin_issue_player_recovery_code(uuid, text, uuid) to anon, authenticated;
grant execute on function public.claim_player_session(text, text, text) to anon, authenticated;

commit;

