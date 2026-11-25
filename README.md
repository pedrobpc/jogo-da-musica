# jogo-da-musica

O site roda no Cloudflare Worker `jogo-da-musica` e usa o Supabase para partidas e pontuação.

## Músicas com vários donos

Cada música pode ter um ou mais donos. No cadastro em lote, use a coluna `donos` e separe nomes com `|`. Na aba **Jogadores**, vincule todos os donos participantes à música. Um voto em qualquer um dos donos corretos concede um ponto.

## Conexão e retorno

A aba **Jogadores** mostra o último sinal de cada aparelho. O site envia sinais a cada 15 segundos e considera a pessoa ativa quando recebeu sinal nos últimos 45 segundos. Celulares podem pausar sinais em segundo plano.

O administrador pode gerar um código de retorno para uma pessoa. Ele é válido por 10 minutos, só pode ser usado uma vez e substitui a sessão anterior. A pessoa informa o código da sala e o código de retorno na tela inicial.

As mudanças de banco estão em `supabase/migrations/202611240001_multi_owner_and_session_security.sql`, `202611240002_player_presence_and_recovery.sql` e `202611240003_recovery_rpc_anon_only.sql`.
