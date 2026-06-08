# Learning Journal

## 1. Objetivo do projeto

Criar um Redis-like do zero em Ruby para estudar backend em profundidade:
protocolo, TCP, concorrencia, TTL, persistencia append-only e recovery.

## 2. Como ler o repositorio primeiro

1. Leia `README.md` para entender o produto e limites.
2. Leia `docs/api/protocol.md` para ver o contrato externo.
3. Leia `test/unit/command_executor_test.rb` para entender os comandos.
4. Leia `lib/rediscraft/application/command_registry.rb` para ver o contrato
   compartilhado de aridade e durabilidade.
5. Leia `lib/rediscraft/domain/store.rb` para ver regras de chave e TTL.
6. Leia `lib/rediscraft/interface/tcp_server.rb` para ver a borda TCP.
7. Leia `lib/rediscraft/infrastructure/aof_log.rb` para ver replay.
8. Leia os ADRs em `docs/adr`.

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

Uma revisao posterior encontrou um detalhe ainda mais especifico no servidor
TCP: a remocao de threads finalizadas existia, mas podia disputar o mesmo mutex
com `stop`, e a thread podia terminar antes de ser registrada. Isso explicava
testes variando de tempo. A correcao registrou a thread antes de liberar o
atendimento do cliente e fez `join` fora do mutex.

Depois que o nucleo ficou estavel, RESP2 foi adicionado como adapter alternativo
ao protocolo textual. A decisao inicial nao foi apagada: texto por linha
continua existindo para estudo e comparacao, enquanto RESP2 ensina framing,
bulk strings e arrays.

Uma nova revisao encontrou duplicacao no contrato de comandos: `CommandExecutor`
validava nomes e aridades, enquanto `AofCommandExecutor` mantinha outra lista de
comandos duraveis. A solucao foi criar `CommandRegistry` como fonte pequena e
unica para nome publico, aridade e durabilidade, sem transformar o executor em um
framework de despacho.

Na fatia seguinte, outro ponto da revisao foi corrigido: `Resp2Protocol`
tratava erro de framing igual a EOF. Agora EOF ainda fecha silenciosamente, mas
erro RESP vira `ERR protocol error` formatado pelo adapter antes de fechar a
conexao daquele cliente.

A revisao Ruby/termonuclear depois dessas duas correcoes encontrou uma duplicacao
menor deixada pelo proprio ajuste: o parsing de inteiro nao negativo para
`EXPIRE` ainda existia no executor e no registry. A regra foi consolidada em
`CommandRegistry.parse_non_negative_integer`.

## 4. Decisao por decisao

Ruby stdlib: escolhido para manter o foco em fundamentos. Rejeitado Rails ou
framework TCP porque esconderiam a parte que o projeto quer ensinar.

Texto por linha antes de RESP: escolhido para permitir leitura facil, testes
menores e AOF simples na primeira versao. Rejeitado RESP no primeiro corte
porque aumentaria o escopo antes de comando, TTL e replay estarem claros.

Registro historico: essa decisao foi boa para o protocolo de cliente, mas fraca
para AOF. A revisao posterior manteve texto por linha na borda TCP e trocou
apenas o formato duravel do AOF.

Mutex unico no store: escolhido porque deixa a invariante de estado simples.
Rejeitado sharding de locks antes de benchmark.

AOF antes de snapshot: escolhido porque replay de comandos ensina recovery.
Snapshot foi deixado para depois porque otimiza startup, mas nao substitui a
licao de durabilidade.

Primeiro AOF textual por linha: escolhido porque era a menor forma de aprender
append e replay. A decisao era defensavel no primeiro recorte, mas ficou fraca
quando o projeto passou a aceitar valores com whitespace e precisou ensinar
durabilidade com menos perda de informacao.

AOF length-prefixed: escolhido depois da revisao porque o formato textual por
linha perdia informacao em valores com whitespace e newline. A alternativa
rejeitada foi usar JSON, porque exigiria escaping de string e ensinaria menos
sobre framing de protocolos.

Primeiro append depois da mutacao: escolhido implicitamente porque era o caminho
mais direto para decorar o executor existente. A revisao mostrou que isso
ensinava uma fronteira de durabilidade ruim.

Append antes da mutacao: escolhido depois da revisao para reduzir surpresa em
caso de falha no arquivo. A alternativa rejeitada foi manter o risco apenas
documentado.

RESP2 como adapter alternativo: escolhido depois que o texto simples ja tinha
cumprido o papel de primeira borda TCP. A alternativa rejeitada foi substituir o
protocolo textual, porque isso apagaria uma etapa importante do aprendizado e
reduziria a comparacao entre os dois modelos.

Contrato central de comandos: escolhido depois que a revisao mostrou risco de
drift entre execucao e AOF. A alternativa rejeitada foi criar um dispatcher
generico por comando agora, porque isso adicionaria indirecao sem necessidade no
escopo atual.

Erro RESP explicito: escolhido porque um cliente precisa distinguir "servidor
fechou porque acabou o stream" de "payload malformado". A alternativa rejeitada
foi manter `nil` como fallback para tudo, porque isso escondia bugs de protocolo
e tornava troubleshooting pior.

## 5. Pros e contras das decisoes principais

Texto simples no protocolo TCP e facil de depurar, mas nao e binario seguro.

RESP2 e mais realista e binario-safe para bulk strings, mas exige mais codigo de
framing e torna a leitura manual menos imediata.

`CommandRegistry` reduz duplicacao entre aplicacao e durabilidade, mas tambem
vira um ponto que precisa ser atualizado ao adicionar comandos. A escolha foi
deliberada: explicitar esse ponto e melhor que espalhar aridade e durabilidade
em dois arquivos.

Responder `ERR protocol error` ajuda clientes e testes de integracao, mas a
conexao e fechada depois do erro. Isso simplifica a recuperacao porque, depois
de um frame RESP invalido, a posicao segura do stream nao e garantida.

Mutex unico e facil de ensinar, mas vira gargalo sob escrita pesada.

Primeiro AOF textual era mais legivel, mas era lossy. AOF length-prefixed
preserva bytes de argumentos melhor que `join/split`, mas e menos legivel e
ainda cresce sem limite.

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

Depois disso, a revisao mostrou que a correcao ainda tinha duas fraquezas: a
thread podia terminar antes de entrar em `@clients`, e `stop` fazia `join`
segurando `@clients_mutex`. A segunda correcao adicionou um `Queue` como gate de
inicio e copiou a lista de clientes antes de fazer `join`.

RESP2 entrou apenas depois de o servidor aceitar um contrato comum de protocolo:
`read_request(io)` e `format(response)`. Essa refatoracao evitou que `TcpServer`
precisasse conhecer detalhes de parsing de texto ou RESP.

O contrato de comandos ficou duplicado na primeira versao porque o caminho mais
direto era validar aridade no executor e decidir durabilidade no decorator de
AOF. A revisao mostrou que isso ficaria fraco assim que novos comandos mutantes
entrassem. `lib/rediscraft/application/command_registry.rb` foi adicionado para
manter a simplicidade, mas com uma fonte unica para esse contrato.

O parser RESP inicialmente resgatava `ProtocolError` e retornava `nil`. Essa era
uma decisao fraca porque misturava erro de protocolo com desconexao normal. A
correcao criou `lib/rediscraft/interface/protocol_error.rb`, fez
`Resp2Protocol` propagar o erro e deixou `TcpServer` formatar a resposta de erro
pela interface atual.

Mesmo depois do `CommandRegistry`, a primeira versao ainda deixou
`parse_non_negative_integer` duplicado no executor. A correcao posterior moveu a
regra de parsing para o contrato de comando e fez `CommandExecutor` reutilizar
essa mesma regra.

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

Red: a revisao de codigo mostrou que `stop` podia esperar segurando o mutex de
tracking; os checks tambem variavam de segundos para centenas de milissegundos.
Green: `TcpServer` passou a registrar a thread antes de libera-la e a fazer
`join` fora do mutex. Verificacao: `bin/test` e `bin/check` passaram em cerca de
0.2s cada no ciclo local.

Red: testes unitarios de RESP2 foram escritos para simple strings, errors,
integers, bulk strings e arrays.
Green: `Resp2Protocol` implementou `read_request` e `format` sem tocar dominio
ou aplicacao.

Red: teste de integracao TCP enviou payload RESP real com bulk string contendo
CRLF.
Green: `TcpServer` passou a ler requests pelo adapter de protocolo e a CLI
ganhou `--protocol text|resp2`.

Red: revisao Ruby/termonuclear do RESP mostrou que null bulk dentro de array de
comando atravessava como `nil`, colidindo com a semantica de valor ausente do
dominio.
Green: `Resp2Protocol` passou a rejeitar arrays de comando com null bulk antes
de chamar a aplicacao.

Red: `test/unit/command_registry_test.rb` foi criado antes da implementacao e
falhou com `LoadError` porque `CommandRegistry` nao existia.
Green: `CommandRegistry` passou a expor comandos publicos, aridade e traducao
duravel para AOF; `CommandExecutor` e `AofCommandExecutor` passaram a usar essa
fonte.
Refactor: as validacoes repetidas de aridade foram removidas dos metodos
privados do executor, mantendo ali apenas comportamento de comando.

Red: `test/unit/resp2_protocol_test.rb` passou a esperar
`Rediscraft::Interface::ProtocolError` para bulk incompleto e a integracao TCP
passou a esperar `-ERR protocol error\r\n` para prefixo RESP invalido.
Green: `Resp2Protocol` parou de engolir erro de parser, `TcpServer` passou a
resgatar `ProtocolError` e escrever a resposta pelo adapter antes de fechar o
socket.

Red: `test/unit/command_registry_test.rb` passou a esperar parsing publico de
inteiro nao negativo e falhou porque o metodo ainda era privado.
Green: `CommandRegistry.parse_non_negative_integer` virou a unica regra usada
tanto por AOF duravel quanto por `CommandExecutor#execute_expire`.

## 8. Quais testes protegem quais decisoes

`test/unit/command_executor_test.rb` protege comando, aridade e TTL.

`test/unit/command_registry_test.rb` protege o contrato compartilhado entre
executor e AOF: nomes publicos, aridade, durabilidade e transformacao de
`EXPIRE` para `EXPIREAT`, alem do parsing de inteiro nao negativo.

`test/unit/text_protocol_test.rb` protege parsing e tipo de resposta.

`test/unit/resp2_protocol_test.rb` protege parser e formatter RESP2, incluindo a
diferenca entre EOF normal e erro de protocolo.

`test/integration/tcp_server_test.rb` protege conexao TCP real e clientes
concorrentes, incluindo comando RESP2 real e erro RESP malformado visivel ao
cliente.

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
| `e247b0c` | Docs precisavam refletir a revisao | Journal e evidencias atualizados | `bin/test`, `bin/check` |
| `972ac64` | Journal precisava separar historia original de decisao final | Registro historico explicito sem apagar evolucao | `bin/test`, `bin/check` |
| `1bec2ca` | `stop` podia disputar mutex com cleanup de clientes | Registro antes do atendimento e join fora do mutex | `bin/test`, `bin/check` |
| `3c94c3f` | Faltava protocolo Redis mais realista | Parser/formatter RESP2 | `bin/test`, `bin/check` |
| `659233c` | TCP lia sempre por linha textual | `TcpServer` passou a ler pelo adapter | `bin/test`, `bin/check` |
| `915c7d1` | RESP2 ainda nao estava exposto por TCP/CLI | Integracao RESP real e `--protocol resp2` | `bin/test`, `bin/check` |
| `ba3ab42` | Null bulk RESP atravessava como `nil` | Adapter rejeita arrays de comando com null bulk | `bin/test`, `bin/check` |
| `f1e637e` | Docs precisavam registrar RESP sem apagar texto inicial | Journal e docs de protocolo atualizados | `bin/test`, `bin/check` |
| `49bdc93` | Evidencias de prontidao RESP estavam desalinhadas | Docs registraram o estado real de RESP2 basico | `bin/test`, `bin/check` |
| `80c1874` | Contrato de comandos duplicava aridade e durabilidade | `CommandRegistry` centraliza nome, aridade e AOF duravel | `ruby -Itest test/unit/command_registry_test.rb`, `bin/test`, `bin/check` |
| `4783bc0` | Journal precisava registrar a evolucao do contrato central | Registro cronologico do `CommandRegistry` e do TDD usado | `bin/test`, `bin/check` |
| `c587e7e` | Erro RESP era indistinguivel de EOF | `ProtocolError` visivel e `ERR protocol error` via TCP | `ruby -Itest test/unit/resp2_protocol_test.rb`, `ruby -Itest test/integration/tcp_server_test.rb`, `bin/test`, `bin/check` |
| `14ea1da` | Docs precisavam refletir erro RESP visivel | Protocolo, erros e journal documentaram `ERR protocol error` | `bin/test`, `bin/check` |
| `6fd48b5` | Parsing de TTL ainda estava duplicado | Executor reutiliza parsing central do `CommandRegistry` | `ruby -Itest test/unit/command_registry_test.rb`, `bin/test`, `bin/check` |

## 10. Checklist de boundaries para futuras features

- Regra de existencia ou expiracao entra em `Domain::Store`.
- Validacao de comando entra em `Application::CommandExecutor`.
- Persistencia entra em `Infrastructure`.
- Parsing e formato de resposta entram em `Interface`.
- Novo protocolo deve implementar `read_request(io)` e `format(response)` sem
  mudar dominio ou aplicacao.
- Novo comando publico deve entrar em `CommandRegistry` antes de executor,
  protocolo ou AOF.
- Novo parser de protocolo deve diferenciar EOF normal de erro de framing.
- Teste unitario vem antes de adapter externo.

## 11. Como adicionar a proxima feature

Para adicionar `INFO`, primeiro defina quais contadores importam. Depois crie
um teste de aplicacao para `INFO`, adicione o estado minimo necessario, exponha
pelo protocolo e registre no journal qual custo de observabilidade foi aceito.

## 12. Limites de producao deixados fora

Sem auth, TLS, ACL, RESP completo, snapshots, AOF compaction, fsync configuravel,
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

Nova revisao encontrou uma melhoria no proprio ajuste de threads: o cleanup
estava correto em intencao, mas `stop` fazia `join` dentro do lock e havia uma
corrida entre criar e registrar a thread. Foi corrigido com gate de inicio e
snapshot da lista antes de `join`.

Revisao Ruby/termonuclear apos RESP encontrou uma melhoria de boundary: null
bulk de RESP nao deveria virar `nil` dentro da aplicacao, porque `nil` ja
representa valor ausente em `GET`. Foi corrigido no adapter RESP.

Importante: o journal deve preservar que as decisoes iniciais existiram e foram
melhoradas. As secoes acima usam "primeiro" e "depois da revisao" de proposito:
o objetivo nao e apresentar uma arquitetura perfeita desde o inicio, mas mostrar
como testes e revisoes mudaram o desenho.
