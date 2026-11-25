-- Multi-owner songs. Apply this migration to the existing Supabase project
-- before publishing the matching index.html.
begin;

create table if not exists public.song_owners (
  song_id uuid not null references public.songs(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (song_id, player_id)
);

create table if not exists public.round_owners (
  round_id uuid not null references public.rounds(id) on delete cascade,
  player_id uuid not null references public.players(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (round_id, player_id)
);

alter table public.rounds
  add column if not exists revealed_owner_player_ids uuid[];

create index if not exists song_owners_player_id_idx
  on public.song_owners(player_id);
create index if not exists round_owners_player_id_idx
  on public.round_owners(player_id);

alter table public.song_owners enable row level security;
alter table public.round_owners enable row level security;
revoke all on table public.song_owners, public.round_owners from anon, authenticated;
revoke all on table public.song_owners, public.round_owners from public;

-- Preserve existing single-owner assignments and historical round ownership.
insert into public.song_owners(song_id, player_id)
select s.id, s.owner_player_id
from public.songs s
where s.owner_player_id is not null
on conflict (song_id, player_id) do nothing;

insert into public.round_owners(round_id, player_id)
select r.id, coalesce(r.owner_player_id, s.owner_player_id)
from public.rounds r
join public.songs s on s.id = r.song_id
where coalesce(r.owner_player_id, s.owner_player_id) is not null
on conflict (round_id, player_id) do nothing;

update public.rounds r
set revealed_owner_player_ids = owners.player_ids
from (
  select ro.round_id, array_agg(ro.player_id order by p.joined_at, p.name) as player_ids
  from public.round_owners ro
  join public.players p on p.id = ro.player_id
  group by ro.round_id
) owners
where owners.round_id = r.id
  and r.owner_revealed = true;

create or replace function public.admin_map_song_owners(
  p_game_id uuid,
  p_password text,
  p_mappings jsonb
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_item jsonb;
  v_song_id uuid;
  v_owner_ids uuid[];
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if jsonb_typeof(p_mappings) is distinct from 'array' then
    raise exception 'Lista de mapeamentos inválida';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_mappings) e(value)
    group by e.value ->> 'song_id'
    having count(*) > 1
  ) then
    raise exception 'A lista contém a mesma música mais de uma vez';
  end if;

  for v_item in
    select e.value from jsonb_array_elements(p_mappings) e(value)
  loop
    v_song_id := nullif(v_item ->> 'song_id', '')::uuid;

    if v_song_id is null or not exists (
      select 1 from public.songs s
      where s.id = v_song_id and s.game_id = p_game_id
    ) then
      raise exception 'Música não encontrada nesta partida';
    end if;

    if jsonb_typeof(v_item -> 'owner_player_ids') is distinct from 'array' then
      raise exception 'A lista de donos da música é inválida';
    end if;

    select coalesce(array_agg(x.player_id order by x.ordinality), array[]::uuid[])
      into v_owner_ids
    from (
      select e.value::uuid as player_id, e.ordinality
      from jsonb_array_elements_text(v_item -> 'owner_player_ids')
        with ordinality as e(value, ordinality)
    ) x;

    if cardinality(v_owner_ids) <>
       (select count(distinct u.player_id) from unnest(v_owner_ids) u(player_id)) then
      raise exception 'A mesma pessoa foi selecionada mais de uma vez';
    end if;

    if exists (
      select 1
      from unnest(v_owner_ids) u(player_id)
      left join public.players p
        on p.id = u.player_id and p.game_id = p_game_id
      where p.id is null
    ) then
      raise exception 'Um dos donos não pertence a esta partida';
    end if;

    delete from public.song_owners so where so.song_id = v_song_id;

    insert into public.song_owners(song_id, player_id)
    select v_song_id, u.player_id
    from unnest(v_owner_ids) u(player_id);

    update public.songs s
    set owner_player_id = case
      when cardinality(v_owner_ids) > 0 then v_owner_ids[1]
      else null
    end
    where s.id = v_song_id and s.game_id = p_game_id;
  end loop;

  return true;
end;
$function$;

revoke all on function public.admin_map_song_owners(uuid, text, jsonb) from public;
grant execute on function public.admin_map_song_owners(uuid, text, jsonb) to anon, authenticated;

create or replace function public.admin_map_song_owner(
  p_game_id uuid,
  p_password text,
  p_song_id uuid,
  p_player_id uuid
)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if not exists (
    select 1 from public.songs s
    where s.id = p_song_id and s.game_id = p_game_id
  ) then
    raise exception 'Música não encontrada nesta partida';
  end if;

  if not exists (
    select 1 from public.players p
    where p.id = p_player_id and p.game_id = p_game_id
  ) then
    raise exception 'Jogador não encontrado nesta partida';
  end if;

  delete from public.song_owners so where so.song_id = p_song_id;
  insert into public.song_owners(song_id, player_id)
  values (p_song_id, p_player_id);

  update public.songs s
  set owner_player_id = p_player_id
  where s.id = p_song_id and s.game_id = p_game_id;

  return true;
end;
$function$;

create or replace function public.admin_mapping_audit(p_game_id uuid, p_password text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  return (
    select jsonb_build_object(
      'total_songs', count(*)::int,
      'mapped_songs', count(*) filter (where exists (
        select 1
        from public.song_owners so
        join public.players p on p.id = so.player_id
        where so.song_id = s.id and p.game_id = p_game_id
      ))::int,
      'unmapped_songs', count(*) filter (where not exists (
        select 1
        from public.song_owners so
        join public.players p on p.id = so.player_id
        where so.song_id = s.id and p.game_id = p_game_id
      ))::int,
      'invalid_mapped_songs', count(*) filter (where exists (
        select 1
        from public.song_owners so
        left join public.players p on p.id = so.player_id
        where so.song_id = s.id and p.game_id is distinct from p_game_id
      ))::int
    )
    from public.songs s
    where s.game_id = p_game_id
  );
end;
$function$;

create or replace function public.admin_state(p_game_id uuid, p_password text)
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

  select jsonb_build_object(
    'game', (select to_jsonb(g) from public.games g where g.id = p_game_id),
    'songs', coalesce((
      select jsonb_agg(
        to_jsonb(s) || jsonb_build_object(
          'owner_player_ids', coalesce((
            select jsonb_agg(so.player_id order by p.joined_at, p.name)
            from public.song_owners so
            join public.players p on p.id = so.player_id
            where so.song_id = s.id and p.game_id = p_game_id
          ), '[]'::jsonb),
          'owner_player_names', coalesce((
            select jsonb_agg(p.name order by p.joined_at, p.name)
            from public.song_owners so
            join public.players p on p.id = so.player_id
            where so.song_id = s.id and p.game_id = p_game_id
          ), '[]'::jsonb)
        ) order by s.sort_order, s.created_at
      )
      from public.songs s
      where s.game_id = p_game_id
    ), '[]'::jsonb),
    'players', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.joined_at)
      from public.players p where p.game_id = p_game_id
    ), '[]'::jsonb),
    'finalResults', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'player_id', fr.player_id,
          'score', fr.score,
          'rank', fr.rank,
          'name', p.name
        ) order by fr.rank, p.name
      )
      from public.final_results fr
      join public.players p on p.id = fr.player_id
      where fr.game_id = p_game_id
    ), '[]'::jsonb),
    'publicRankings', coalesce((
      select jsonb_agg(to_jsonb(pr) order by pr.rank desc, pr.player_name)
      from public.public_rankings pr where pr.game_id = p_game_id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

create or replace function public.admin_start_round(
  p_game_id uuid,
  p_password text,
  p_song_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_round_id uuid;
  v_number int;
  v_owner_ids uuid[];
  v_owner_id uuid;
  v_unmapped int;
  v_invalid int;
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  select
    count(*) filter (where not exists (
      select 1
      from public.song_owners so
      join public.players p on p.id = so.player_id
      where so.song_id = s.id and p.game_id = p_game_id
    )),
    count(*) filter (where exists (
      select 1
      from public.song_owners so
      left join public.players p on p.id = so.player_id
      where so.song_id = s.id and p.game_id is distinct from p_game_id
    ))
  into v_unmapped, v_invalid
  from public.songs s
  where s.game_id = p_game_id;

  if v_unmapped > 0 or v_invalid > 0 then
    raise exception 'Existem músicas sem dono válido. Corrija a aba Jogadores antes de iniciar.';
  end if;

  if exists (
    select 1 from public.rounds r
    where r.game_id = p_game_id and r.status in ('voting', 'results', 'reveal')
  ) then
    raise exception 'Já existe uma rodada em andamento';
  end if;

  if not exists (
    select 1 from public.songs s
    where s.id = p_song_id and s.game_id = p_game_id and s.used = false
  ) then
    raise exception 'Música indisponível ou sem dono mapeado';
  end if;

  select array_agg(so.player_id order by p.joined_at, p.name)
  into v_owner_ids
  from public.song_owners so
  join public.players p on p.id = so.player_id and p.game_id = p_game_id
  where so.song_id = p_song_id;

  if coalesce(cardinality(v_owner_ids), 0) = 0 then
    raise exception 'Música indisponível ou sem dono mapeado';
  end if;

  v_owner_id := v_owner_ids[1];

  select coalesce(max(r.number), 0) + 1
  into v_number
  from public.rounds r
  where r.game_id = p_game_id;

  insert into public.rounds(
    game_id, number, song_id, owner_player_id, status, duration_sec,
    starts_at, ends_at, owner_revealed, revealed_owner_player_id,
    revealed_owner_player_ids
  )
  values (
    p_game_id, v_number, p_song_id, v_owner_id, 'voting', 30,
    now(), now() + interval '30 seconds', false, null, null
  )
  returning id into v_round_id;

  insert into public.round_owners(round_id, player_id)
  select v_round_id, u.player_id
  from unnest(v_owner_ids) u(player_id);

  update public.songs s
  set used = true
  where s.id = p_song_id and s.game_id = p_game_id;

  update public.games g
  set phase = 'voting',
      round_no = v_number,
      current_round_id = v_round_id
  where g.id = p_game_id;

  return v_round_id;
end;
$function$;

create or replace function public.admin_end_round(p_game_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_round_id uuid;
  v_song_id uuid;
  v_title text;
  v_artist text;
  v_album text;
  v_spotify text;
  v_owner_ids uuid[];
  v_owner_id uuid;
  v_owner text;
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  select g.current_round_id into v_round_id
  from public.games g where g.id = p_game_id;

  if v_round_id is null then
    raise exception 'Nenhuma rodada atual';
  end if;

  select r.song_id, s.title, s.artist, s.album_art_url, s.spotify_url
  into v_song_id, v_title, v_artist, v_album, v_spotify
  from public.rounds r
  join public.songs s on s.id = r.song_id and s.game_id = p_game_id
  where r.id = v_round_id and r.game_id = p_game_id and r.status = 'voting';

  if v_song_id is null then
    return false;
  end if;

  select
    array_agg(ro.player_id order by p.joined_at, p.name),
    string_agg(p.name, ' • ' order by p.joined_at, p.name)
  into v_owner_ids, v_owner
  from public.round_owners ro
  join public.players p on p.id = ro.player_id and p.game_id = p_game_id
  where ro.round_id = v_round_id;

  if coalesce(cardinality(v_owner_ids), 0) = 0 then
    raise exception 'A música ainda não tem dono mapeado';
  end if;

  v_owner_id := v_owner_ids[1];

  delete from public.round_results where round_id = v_round_id;

  insert into public.round_results(round_id, choice_player_id, player_name, vote_count)
  select v_round_id, p.id, p.name, count(v.id)::int
  from public.players p
  left join public.votes v
    on v.choice_player_id = p.id and v.round_id = v_round_id
  where p.game_id = p_game_id
  group by p.id, p.name;

  update public.rounds r
  set status = 'reveal',
      reveal_until = null,
      revealed_title = v_title,
      revealed_artist = v_artist,
      revealed_owner = v_owner,
      revealed_album_art_url = v_album,
      revealed_spotify_url = v_spotify,
      revealed_owner_player_id = v_owner_id,
      revealed_owner_player_ids = null,
      owner_revealed = false,
      total_votes = (select count(*) from public.votes v where v.round_id = v_round_id)
  where r.id = v_round_id and r.game_id = p_game_id;

  update public.games g set phase = 'reveal' where g.id = p_game_id;

  return true;
end;
$function$;

create or replace function public.admin_reveal_owner(p_game_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_round_id uuid;
  v_status text;
  v_owner_ids uuid[];
  v_owner_id uuid;
  v_title text;
  v_artist text;
  v_album text;
  v_spotify text;
  v_owner text;
  v_avatar text;
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  select g.current_round_id, r.status
  into v_round_id, v_status
  from public.games g
  left join public.rounds r on r.id = g.current_round_id
  where g.id = p_game_id;

  if v_round_id is null then
    raise exception 'Nenhuma rodada ativa';
  end if;

  if v_status not in ('reveal', 'results') then
    raise exception 'A rodada ainda não está pronta para revelação';
  end if;

  select s.title, s.artist, s.album_art_url, s.spotify_url
  into v_title, v_artist, v_album, v_spotify
  from public.rounds r
  join public.songs s on s.id = r.song_id and s.game_id = p_game_id
  where r.id = v_round_id and r.game_id = p_game_id;

  select
    array_agg(ro.player_id order by p.joined_at, p.name),
    string_agg(p.name, ' • ' order by p.joined_at, p.name),
    (array_agg(coalesce(p.avatar_emoji, '😀') order by p.joined_at, p.name))[1]
  into v_owner_ids, v_owner, v_avatar
  from public.round_owners ro
  join public.players p on p.id = ro.player_id and p.game_id = p_game_id
  where ro.round_id = v_round_id;

  if coalesce(cardinality(v_owner_ids), 0) = 0 then
    raise exception 'A música ainda não tem dono mapeado';
  end if;

  v_owner_id := v_owner_ids[1];

  update public.rounds r
  set status = 'reveal',
      reveal_until = now() + interval '10 seconds',
      owner_revealed = true,
      revealed_owner_player_id = v_owner_id,
      revealed_owner_player_ids = v_owner_ids,
      revealed_owner = v_owner,
      revealed_owner_avatar = coalesce(v_avatar, '😀'),
      revealed_title = v_title,
      revealed_artist = v_artist,
      revealed_album_art_url = v_album,
      revealed_spotify_url = v_spotify
  where r.id = v_round_id
    and r.game_id = p_game_id
    and r.owner_revealed = false;

  update public.games g set phase = 'reveal' where g.id = p_game_id;

  return true;
end;
$function$;

create or replace function public.admin_round_scoreboard(p_game_id uuid, p_password text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_result jsonb;
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  with completed_rounds as (
    select r.id, r.number, r.song_id, s.title as song_title, s.album_art_url,
      coalesce((
        select string_agg(p2.name, ' • ' order by p2.joined_at, p2.name)
        from public.round_owners ro
        join public.players p2 on p2.id = ro.player_id and p2.game_id = p_game_id
        where ro.round_id = r.id
      ), coalesce(op.name, s.owner)) as owner_name
    from public.rounds r
    join public.songs s on s.id = r.song_id and s.game_id = p_game_id
    left join public.players op
      on op.id = coalesce(r.owner_player_id, s.owner_player_id)
     and op.game_id = p_game_id
    where r.game_id = p_game_id and r.status <> 'voting'
  ),
  round_points as (
    select cr.id as round_id, cr.number, cr.song_id, cr.song_title, cr.album_art_url,
      cr.owner_name, p.id as player_id, p.name,
      case when exists (
        select 1 from public.round_owners ro
        where ro.round_id = cr.id and ro.player_id = v.choice_player_id
      ) then 1 else 0 end as points
    from completed_rounds cr
    cross join public.players p
    left join public.votes v on v.round_id = cr.id and v.player_id = p.id
    where p.game_id = p_game_id
  ),
  totals as (
    select p.id as player_id, p.name, coalesce(sum(rp.points), 0)::int as score
    from public.players p
    left join round_points rp on rp.player_id = p.id
    where p.game_id = p_game_id
    group by p.id, p.name
  ),
  round_json as (
    select rp.round_id, rp.number, rp.song_id, rp.song_title, rp.album_art_url,
      rp.owner_name,
      jsonb_agg(jsonb_build_object(
        'player_id', rp.player_id,
        'name', rp.name,
        'points', rp.points,
        'cumulative_points', (
          select coalesce(sum(rp2.points), 0)::int
          from round_points rp2
          where rp2.player_id = rp.player_id and rp2.number <= rp.number
        )
      ) order by rp.name) as scores
    from round_points rp
    group by rp.round_id, rp.number, rp.song_id, rp.song_title, rp.album_art_url, rp.owner_name
  )
  select jsonb_build_object(
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.player_id, 'name', t.name) order by t.name)
      from totals t
    ), '[]'::jsonb),
    'rounds', coalesce((
      select jsonb_agg(jsonb_build_object(
        'round_id', rj.round_id, 'number', rj.number, 'song_id', rj.song_id,
        'song_title', rj.song_title, 'album_art_url', rj.album_art_url,
        'owner_name', rj.owner_name, 'scores', rj.scores
      ) order by rj.number)
      from round_json rj
    ), '[]'::jsonb),
    'totals', coalesce((
      select jsonb_agg(jsonb_build_object('player_id', t.player_id, 'name', t.name, 'score', t.score)
        order by t.score desc, t.name)
      from totals t
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

create or replace function public.admin_start_final(p_game_id uuid, p_password text)
returns boolean
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
begin
  if not public.verify_admin(p_game_id, p_password) then
    raise exception 'Senha administrativa inválida';
  end if;

  if exists (
    select 1 from public.rounds r
    where r.game_id = p_game_id and r.status in ('voting', 'results', 'reveal')
  ) then
    raise exception 'Ainda existe uma rodada em andamento';
  end if;

  if exists (
    select 1 from public.songs s
    where s.game_id = p_game_id and s.used = false
  ) then
    raise exception 'Ainda existem músicas não tocadas';
  end if;

  if exists (
    select 1
    from public.songs s
    where s.game_id = p_game_id
      and not exists (
        select 1
        from public.song_owners so
        join public.players p on p.id = so.player_id
        where so.song_id = s.id and p.game_id = p_game_id
      )
  ) or exists (
    select 1
    from public.songs s
    join public.song_owners so on so.song_id = s.id
    left join public.players p on p.id = so.player_id
    where s.game_id = p_game_id and p.game_id is distinct from p_game_id
  ) then
    raise exception 'Existem músicas com dono não mapeado ou inválido';
  end if;

  delete from public.final_results fr where fr.game_id = p_game_id;

  insert into public.final_results(game_id, player_id, score, rank)
  select p.game_id, p.id,
    coalesce(sum(case when exists (
      select 1
      from public.round_owners ro
      where ro.round_id = r.id and ro.player_id = v.choice_player_id
    ) then 1 else 0 end), 0)::int,
    1
  from public.players p
  left join public.votes v on v.player_id = p.id
  left join public.rounds r on r.id = v.round_id and r.game_id = p_game_id
  left join public.songs s on s.id = r.song_id and s.game_id = p_game_id
  where p.game_id = p_game_id
  group by p.game_id, p.id;

  update public.final_results fr
  set rank = q.calculated_rank
  from (
    select fr2.player_id, rank() over(order by fr2.score desc)::int as calculated_rank
    from public.final_results fr2
    where fr2.game_id = p_game_id
  ) q
  where fr.game_id = p_game_id and fr.player_id = q.player_id;

  delete from public.public_rankings where game_id = p_game_id;

  update public.games g
  set phase = 'final_ranking', final_reveal_rank = null
  where g.id = p_game_id;

  return true;
end;
$function$;

create or replace function public.get_round_missing_players(p_round_id uuid, p_session_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_game_id uuid;
  v_player_id uuid;
  v_game_hash text;
  v_legacy_hash text;
  v_result jsonb;
begin
  select r.game_id into v_game_id
  from public.rounds r
  where r.id = p_round_id;

  if v_game_id is null then
    raise exception 'Rodada não encontrada';
  end if;

  v_game_hash := public.hash_session_token(p_session_token || ':' || v_game_id::text);
  v_legacy_hash := public.hash_session_token(p_session_token);

  select ps.player_id into v_player_id
  from public.player_sessions ps
  join public.players p on p.id = ps.player_id
  where p.game_id = v_game_id
    and ps.session_token_hash in (v_game_hash, v_legacy_hash)
  limit 1;

  if v_player_id is null then
    raise exception 'Sessão de jogador inválida';
  end if;

  select jsonb_build_object(
    'answered_count', (
      select count(*)::int from public.votes v where v.round_id = p_round_id
    ),
    'total_players', (
      select count(*)::int from public.players p where p.game_id = v_game_id
    ),
    'missing_players', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', p.id, 'name', p.name)
        order by p.joined_at, p.name
      )
      from public.players p
      where p.game_id = v_game_id
        and not exists (
          select 1 from public.votes v
          where v.round_id = p_round_id and v.player_id = p.id
        )
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;
create or replace function public.get_monitor_round_result(p_round_id uuid)
returns table(player_id uuid, player_name text, avatar_emoji text, correct boolean)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_game_id uuid;
begin
  select r.game_id into v_game_id
  from public.rounds r
  where r.id = p_round_id
    and r.status in ('reveal', 'done')
    and r.owner_revealed = true;

  if v_game_id is null then
    return;
  end if;

  return query
  select p.id, p.name, p.avatar_emoji,
    exists (
      select 1
      from public.round_owners ro
      where ro.round_id = p_round_id and ro.player_id = v.choice_player_id
    ) as correct
  from public.votes v
  join public.players p on p.id = v.player_id and p.game_id = v_game_id
  where v.round_id = p_round_id
  order by correct desc, p.joined_at, p.name;
end;
$function$;

create or replace function public.join_game(
  p_game_id uuid,
  p_name text,
  p_session_token text,
  p_avatar_emoji text default '😀'::text
)
returns table(result_player_id uuid, result_player_name text, result_avatar_emoji text)
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_game_phase text;
  v_player_id uuid;
  v_session_hash text;
  v_legacy_hash text;
  v_name text;
  v_avatar text;
begin
  v_name := trim(coalesce(p_name, ''));
  v_avatar := left(coalesce(nullif(trim(p_avatar_emoji), ''), '😀'), 8);

  if length(v_name) = 0 then
    raise exception 'Nome inválido';
  end if;

  if length(coalesce(p_session_token, '')) < 12 then
    raise exception 'Sessão inválida';
  end if;

  select g.phase into v_game_phase
  from public.games g
  where g.id = p_game_id;

  if v_game_phase is null then
    raise exception 'Partida não encontrada';
  end if;

  v_session_hash := public.hash_session_token(
    p_session_token || ':' || p_game_id::text
  );
  v_legacy_hash := public.hash_session_token(p_session_token);

  -- Reentrada exige o token já salvo para esse jogador. O nome público,
  -- sozinho, nunca reassocia uma sessão a uma identidade existente.
  select ps.player_id into v_player_id
  from public.player_sessions ps
  join public.players pl on pl.id = ps.player_id
  where pl.game_id = p_game_id
    and ps.session_token_hash in (v_session_hash, v_legacy_hash)
  limit 1;

  if v_player_id is null then
    if v_game_phase <> 'lobby' then
      raise exception 'Não foi possível recuperar sua sessão. Volte usando o mesmo aparelho e navegador; se perdeu o acesso, peça ajuda ao administrador.';
    end if;

    if exists (
      select 1 from public.players pl
      where pl.game_id = p_game_id
        and lower(trim(pl.name)) = lower(v_name)
    ) then
      raise exception 'Esse nome já está em uso. Volte usando o aparelho e navegador em que você entrou.';
    end if;

    insert into public.players(game_id, name, avatar_emoji)
    values (p_game_id, v_name, v_avatar)
    returning id into v_player_id;

    insert into public.player_sessions(player_id, session_token_hash)
    values (v_player_id, v_session_hash)
    on conflict (player_id) do update
      set session_token_hash = excluded.session_token_hash;
  else
    update public.players pl
    set avatar_emoji = v_avatar
    where pl.id = v_player_id and pl.game_id = p_game_id;

    insert into public.player_sessions(player_id, session_token_hash)
    values (v_player_id, v_session_hash)
    on conflict (player_id) do update
      set session_token_hash = excluded.session_token_hash;
  end if;

  return query
  select pl.id, pl.name, pl.avatar_emoji
  from public.players pl
  where pl.id = v_player_id;
end;
$function$;
commit;

