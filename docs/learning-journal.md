# Learning Journal

## 1. Objetivo do projeto

Criar um Redis-like do zero em Ruby para estudar backend em profundidade:
protocolo, TCP, concorrencia, TTL, persistencia append-only e recovery.

## 2. Como ler o repositorio primeiro

1. Leia `README.md` para entender o produto e limites.
2. Leia `docs/api/protocol.md` para ver o contrato externo.
3. Leia `test/unit/command_executor_test.rb` para entender os comandos.
4. Leia `lib/rediscraft/domain/store.rb` para ver regras de chave e TTL.
5. Leia `lib/rediscraft/interface/tcp_server.rb` para ver a borda TCP.
6. Leia `lib/rediscraft/infrastructure/aof_log.rb` para ver replay.
7. Leia os ADRs em `docs/adr`.

## 3. Historia cronologica da implementacao

Primeiro foi criado o projeto Ruby puro com `minitest`, `bin/test` e
`bin/check`. O primeiro teste falhou por falta de executor e store; a
implementacao minima adicionou `PING`, `SET` e `GET`.

Depois entraram os comandos de chave e TTL. A regra de expiracao ficou no
dominio porque ela define se uma chave existe publicamente.

Em seguida veio a interface TCP. O servidor apenas recebe linhas, chama o caso
de uso e formata resposta; ele nao decide semantica de chave.

Por fim foi adicionado AOF. A primeira versao registrava `EXPIRE key 60`, mas
isso reiniciaria TTL depois de restart. A correcao registra `EXPIREAT` com
timestamp absoluto.

Depois da revisao Ruby/termonuclear, quatro pontos foram corrigidos: `EXPIREAT`
saiu da API publica, AOF passou a ser gravado antes da mutacao em memoria, o
codec do AOF deixou de usar `join/split`, e o servidor TCP passou a remover
threads finalizadas do rastreamento interno.

## 4. Decisao por decisao

Ruby stdlib: escolhido para manter o foco em fundamentos. Rejeitado Rails ou
framework TCP porque esconderiam a parte que o projeto quer ensinar.

Texto por linha antes de RESP: escolhido para permitir leitura facil, testes
menores e AOF simples. Rejeitado RESP no primeiro corte porque aumentaria o
escopo antes de comando, TTL e replay estarem claros.

Mutex unico no store: escolhido porque deixa a invariante de estado simples.
Rejeitado sharding de locks antes de benchmark.

AOF antes de snapshot: escolhido porque replay de comandos ensina recovery.
Snapshot foi deixado para depois porque otimiza startup, mas nao substitui a
licao de durabilidade.

AOF length-prefixed: escolhido depois da revisao porque o formato textual por
linha era facil de ler, mas perdia informacao em valores com whitespace e
newline. A alternativa rejeitada foi usar JSON, porque exigiria escaping de
string e ensinaria menos sobre framing de protocolos.

Append antes da mutacao: escolhido para reduzir surpresa em caso de falha no
arquivo. A alternativa rejeitada foi manter o risco apenas documentado.

## 5. Pros e contras das decisoes principais

Texto simples e facil de depurar, mas nao e binario seguro.

Mutex unico e facil de ensinar, mas vira gargalo sob escrita pesada.

AOF length-prefixed preserva bytes de argumentos melhor que `join/split`, mas e
menos legivel e ainda cresce sem limite.

Thread por cliente e direto, mas nao modela multiplexacao eficiente.

## 6. Erros, decisoes fracas ou correcoes

O primeiro runner de teste nao adicionava `test/` ao load path. Foi corrigido
antes da implementacao.

O formatter inicialmente usava heuristica para decidir se string era status ou
bulk. Isso quebraria `GET key` quando o valor fosse `OK`. A correcao adicionou
tipo de resposta explicito em `Rediscraft::Application::Response`.

AOF inicialmente podia registrar expiracao relativa. Foi corrigido para
`EXPIREAT`.

`EXPIREAT` inicialmente ficou acessivel ao cliente como comando publico. Isso
foi corrigido porque era um detalhe interno de replay, nao parte do contrato TCP.

AOF inicialmente acontecia depois da mutacao em memoria. Isso foi corrigido
para append antes da mutacao em comandos duraveis.

AOF inicialmente usava linhas com `parts.join(" ")`. Isso foi corrigido com
frames length-prefixed.

O servidor TCP mantinha referencias para threads ja encerradas. Isso foi
corrigido removendo a thread no `ensure` do worker.

## 7. Como o TDD foi usado

Red: `test/unit/command_executor_test.rb` falhou por falta de executor.
Green: `CommandExecutor` e `Store` minimos passaram `PING`, `SET`, `GET`.
Refactor: comandos adicionais foram separados em metodos privados.

Red: testes de TCP falharam por falta de `TcpServer`.
Green: `TextProtocol` e `TcpServer` implementaram o caminho de socket.
Refactor: `QUIT` ficou na borda TCP.

Red: teste de AOF falhou por falta de decorator e log.
Green: `AofCommandExecutor` e `AofLog` gravaram e reproduziram comandos.
Refactor: `EXPIRE` passou a ser persistido como `EXPIREAT`.

Red: revisao encontrou `EXPIREAT` publico e teste novo mostrou que o comando
era aceito pelo executor.
Green: replay passou a aplicar `EXPIREAT` internamente no store e o executor
publico voltou a responder comando desconhecido.

Red: teste com AOF falso que levanta `IOError` mostrou que o store podia mudar
sem durabilidade.
Green: `AofCommandExecutor` passou a gerar e gravar o registro duravel antes de
chamar o executor interno.

Red: teste com valor contendo newline mostrou que AOF por linha perdia dados.
Green: `AofLog` passou a usar frames length-prefixed.

Red: teste de conexao `QUIT` mostrou que threads finalizadas continuavam
contadas.
Green: `TcpServer` remove a thread finalizada do tracking no `ensure`.

## 8. Quais testes protegem quais decisoes

`test/unit/command_executor_test.rb` protege comando, aridade e TTL.

`test/unit/text_protocol_test.rb` protege parsing e tipo de resposta.

`test/integration/tcp_server_test.rb` protege conexao TCP real e clientes
concorrentes.

`test/unit/aof_command_executor_test.rb` protege AOF, replay, append antes de
mutacao e ignorar frame parcial.

## 9. Timeline dos commits atomicos

| Commit | Problema | Mudanca | Teste/verificacao |
| --- | --- | --- | --- |
| `ea4137d` | Projeto inexistente | Bootstrap Ruby, README, specs e primeiro teste | `bin/test`, `bin/check` |
| `3ff238d` | Faltavam comandos e TTL | `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `PERSIST` | `bin/test`, `bin/check` |
| `a01282c` | Faltava interface externa | TCP server e protocolo textual | `bin/test`, `bin/check` |
| `26ae7f6` | Faltava recovery | AOF com replay e `EXPIREAT` | `bin/test`, `bin/check` |
| `9f86d29` | Formatter confundia valor com status | Tipos explicitos de resposta e AOF mutex | `bin/test`, `bin/check` |
| `b92854d` | Faltava pacote de documentacao | Journal, case study, docs e CI | `bin/test`, `bin/check` |
| `54846e6` | Timeline precisava do hash final | Atualizacao final do journal | `bin/test`, `bin/check` |
| `94145b9` | Timeline ainda tinha referencia pendente | Finalizacao do journal | `bin/test`, `bin/check` |
| `5abec69` | `EXPIREAT` vazava para a API publica | Replay interno aplica `EXPIREAT` sem expor comando | `bin/test`, `bin/check` |
| `10ce600` | Store podia mudar antes do append AOF | AOF append antes da mutacao duravel | `bin/test`, `bin/check` |
| `c41a2ac` | AOF textual perdia informacao | Frames length-prefixed | `bin/test`, `bin/check` |
| `f65f870` | Threads finalizadas ficavam rastreadas | Cleanup no `ensure` do worker TCP | `bin/test`, `bin/check` |
| `PENDING` | Docs precisavam refletir a revisao | Journal e evidencias atualizados | `bin/test`, `bin/check` |

## 10. Checklist de boundaries para futuras features

- Regra de existencia ou expiracao entra em `Domain::Store`.
- Validacao de comando entra em `Application::CommandExecutor`.
- Persistencia entra em `Infrastructure`.
- Parsing e formato de resposta entram em `Interface`.
- Teste unitario vem antes de adapter externo.

## 11. Como adicionar a proxima feature

Para adicionar `INFO`, primeiro defina quais contadores importam. Depois crie
um teste de aplicacao para `INFO`, adicione o estado minimo necessario, exponha
pelo protocolo e registre no journal qual custo de observabilidade foi aceito.

## 12. Limites de producao deixados fora

Sem auth, TLS, ACL, RESP, snapshots, AOF compaction, fsync configuravel,
replicacao, clustering, limite de conexoes, metricas e backpressure.

## 13. Resultado das revisoes de qualidade

Revisao estrutural encontrou dois pontos relevantes: formatter por heuristica e
AOF append sem mutex. Ambos foram corrigidos.

Revisao Ruby encontrou que o projeto usa stdlib, objetos pequenos e testes
diretos. O risco restante e performance: thread por cliente e mutex unico sao
adequados para estudo, nao para alto throughput.

Revisao Ruby/Rails + termonuclear posterior encontrou quatro achados:
`EXPIREAT` publico sem AOF, mutacao antes de append, AOF lossy por `join/split`,
e tracking permanente de threads. Todos foram corrigidos. Risco restante: ainda
nao existe `fsync` configuravel, limite de conexoes, backpressure ou benchmark
de contencao.
