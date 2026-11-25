-- The site uses the Supabase anon role; authenticated users do not need these RPCs.
begin;

revoke execute on function public.player_heartbeat(uuid, text) from authenticated;
revoke execute on function public.admin_player_connections(uuid, text) from authenticated;
revoke execute on function public.admin_issue_player_recovery_code(uuid, text, uuid) from authenticated;
revoke execute on function public.claim_player_session(text, text, text) from authenticated;

commit;
