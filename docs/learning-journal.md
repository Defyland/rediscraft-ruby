# Learning Journal

## 1. Objetivo do projeto

Criar um Redis-like do zero em Ruby para estudar backend em profundidade:
protocolo, TCP, concorrencia, TTL, persistencia append-only e recovery.

## 2. Os conceitos que este projeto ensina (leia primeiro)

Este journal nasceu cronologico: rodada apos rodada de "primeiro fiz assim, depois
a revisao mostrou que...". Isso e bom para ver o desenho evoluir, mas ruim para uma
primeira leitura. Esta secao e o atalho: os conceitos centrais de backend que o
projeto materializa, cada um com onde aprende-lo a fundo. Leia isto, depois siga a
ordem de leitura no fim da secao.

1. **Framing de protocolo.** TCP e um stream de bytes sem fronteiras de mensagem.
   Quem fala o protocolo precisa decidir onde um comando termina: por linha (texto)
   ou por tamanho prefixado (RESP). Num event loop os bytes chegam em pedacos, entao
   o parser tem de ser incremental: consumir o que ha e dizer "incompleto" sem
   bloquear. Veja secoes 14 e 16; `lib/rediscraft/interface/*_protocol.rb`.

2. **Durabilidade e a escada do fsync.** Persistir mutacoes como um log (write-ahead)
   permite reconstruir o estado. Mas "escrevi no arquivo" tem niveis: buffer da
   linguagem, page cache do SO, disco (`fsync`), e a entrada de diretorio
   (`fsync` do diretorio). Cada nivel protege contra uma falha diferente. Veja
   secoes 15 e 18; `lib/rediscraft/infrastructure/aof_log.rb`.

3. **Modelos de concorrencia, e a GVL.** O projeto comecou com uma thread por
   cliente e migrou para um event loop single-threaded, o modelo do Redis. Entender
   por que e quando isso ajuda exige entender o que a GVL do Ruby garante e o que
   nao garante. Veja secoes 16 e 17.

4. **Complexidade num servidor single-threaded.** Quando uma thread serve todos, um
   comando O(N) congela todos os clientes pela duracao. Saber a complexidade de cada
   comando deixa de ser academico e vira requisito. O `INFO` ensinou isso na pratica.
   Veja secao 18; o benchmark em `benchmarks/`.

5. **Expiracao: preguicosa e ativa.** Uma chave com TTL pode ser despejada quando
   lida (preguicosa) ou por um ciclo de fundo que amostra chaves (ativa). Sem a
   ativa, uma chave nunca mais tocada vaza memoria. Veja secao 18; `Store`.

6. **Limites de recurso.** Um servidor honesto se protege de clientes que abusam:
   um cliente que nao le suas respostas faria o buffer de escrita crescer sem
   limite. Cap e derrube. Veja secao 18; `TcpServer`.

7. **Medir, nao so raciocinar.** Quase toda afirmacao de performance neste journal
   foi, por muito tempo, uma hipotese sem numero. O benchmark existe para
   transformar hipotese em medida, e para refuta-la quando errada. Veja secao 18 e
   `docs/benchmarks/methodology.md`.

8. **Testes e seus limites.** Testes deterministicos checam os casos que voce
   pensou. Fuzzing checa os que nao pensou; um teste de crash valida durabilidade
   contra a morte real do processo. Cada tecnica tem uma fronteira do que prova.
   Veja secao 18; `test/`.

Ordem de leitura sugerida depois disto:

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

A mesma revisao final revisitou a correcao antiga de null bulk em RESP. Ela
impedia `nil` de chegar diretamente ao dominio, mas ainda usava `[]` como
sentinela e chamava a aplicacao. Com `ProtocolError` disponivel, null bulk em
array de comando passou a ser erro de protocolo no proprio adapter RESP.

Uma revisao posterior focada em lifecycle e recovery encontrou tres pontos:
`TcpServer#stop` fechava o listener, mas nao os sockets de clientes ociosos; o
decoder AOF aceitava bytes extras dentro de um frame; e o contrato entre comandos
duraveis emitidos e replay precisava de um teste de cobertura explicito. As
correcoes mantiveram o desenho pequeno: tracking de thread para socket no TCP,
decoder AOF estrito e teste de contrato sem criar um aplicador novo.

A rodada seguinte de revisao Ruby/termonuclear olhou para concorrencia e limpeza
estrutural e encontrou quatro pontos. O mais grave estava no `AofCommandExecutor`:
ele gravava o registro duravel e mutava o store em duas secoes criticas separadas,
entao dois clientes escrevendo a mesma chave podiam gravar no AOF em uma ordem e
aplicar no store em outra, fazendo o replay divergir do estado vivo. Os outros
tres eram de qualidade: o formatter textual ainda carregava a heuristica antiga
que ja tinha sido substituida por tipos de resposta explicitos, `Store#delete`
escondia uma chamada load-bearing de expiracao preguicosa, e o help do `--aof`
ainda dizia "future support" para um recurso ja ligado. As correcoes mantiveram o
desenho pequeno: um unico mutex de escrita no decorator de AOF, remocao de codigo
morto no formatter, intencao explicita no delete e texto de CLI alinhado ao
comportamento.

A rodada seguinte saiu do modo "revisao corrige achados" e entrou no modo
"evolucao dirigida": subir o Ruby para 3.4.9 e implementar quatro itens que antes
estavam documentados como fora de escopo. Primeiro o determinismo do EXPIRE: o
registro duravel persistia um instante absoluto, mas a execucao viva re-resolvia
um TTL relativo no store, com outro relogio e outra precisao, entao `expires_at`
vivo podia divergir do `expires_at` reconstruido por replay. A correcao fez a
execucao viva aplicar o mesmo registro que persiste, com uma unica leitura de
relogio e precisao cheia. Depois, `fsync` configuravel no AOF, separando a
garantia de durabilidade da garantia de throughput. Depois, o comando `INFO`
expondo gauges de keyspace, a primeira fatia de observabilidade. Por fim,
compaction do AOF reescrevendo o log a partir do estado vivo, encerrando o
crescimento ilimitado.

A rodada seguinte foi a maior mudanca de direcao do projeto: trocar
thread-por-cliente por um event loop single-threaded. O servidor antigo dava uma
thread por conexao e bloqueava em `read_request(io)`. O novo `TcpServer` e um
reactor: uma thread roda `IO.select` sobre o listener, um self-pipe de shutdown e
todos os sockets de cliente, com leitura e escrita nao bloqueantes e um buffer por
conexao. Para isso, o contrato de protocolo deixou de ser `read_request(io)`
(pull, bloqueante) e virou `consume(buffer)` (push, incremental): devolve
`[parts, rest]` para um frame completo, `nil` quando faltam bytes, e levanta
`ProtocolError` em frame malformado. Foi feito em tres commits: primeiro o parsing
incremental nos protocolos (aditivo), depois a reescrita do servidor, depois a
remocao do `read_request` morto. Os locks das camadas internas ficaram de
proposito: a mudanca de concorrencia mora so na interface.

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

Fechar sockets ativos em `stop`: escolhido porque o servidor ja rastreava
clientes e precisava completar o lifecycle que iniciou. A alternativa rejeitada
foi deixar clientes ociosos dependerem de timeout externo, porque isso mantinha
threads bloqueadas em leitura.

Frame AOF estrito: escolhido porque recovery nao deve aplicar um comando quando
o payload tem bytes sobrando. A alternativa rejeitada foi tolerar lixo no fim do
frame, porque isso escondia corrupcao parcial.

Mutex de escrita no AofCommandExecutor: escolhido porque o registro duravel e a
mutacao em memoria precisam ser um unico ponto de linearizacao. A alternativa
rejeitada foi confiar no mutex do store e no mutex do AofLog separadamente, porque
cada um protege apenas a sua propria secao critica e nenhum garante que a ordem de
append seja a mesma ordem de aplicacao. So as leituras ficam fora desse mutex,
porque elas nao entram no AOF e nao podem reordenar o historico duravel.

Remover a heuristica do formatter textual: escolhido porque o tipo de resposta ja
e explicito desde `Response`. A alternativa rejeitada foi manter o ramo de
fallback "por seguranca"; na pratica ele era inalcancavel e, pior, transformava
uma violacao de contrato em string silenciosa em vez de falhar alto.

Tornar a expiracao preguicosa explicita em delete: escolhido porque a chamada
`live_entry_for` era load-bearing mas invisivel. A alternativa rejeitada foi
deixar a intencao implicita; uma futura limpeza poderia remover a linha "sem
efeito" e quebrar `DEL` em chave expirada sem nenhum teste vermelho.

Corrigir o help do `--aof`: escolhido porque a saida operacional deve refletir o
comportamento real. A alternativa rejeitada foi tratar texto de CLI como
cosmetico; um help que promete "future support" para um recurso ativo corroi a
confianca de quem opera o servidor.

Aplicar o registro persistido na execucao viva: escolhido para que a execucao e o
replay derivem do mesmo instante e da mesma precisao. A alternativa rejeitada foi
apenas compartilhar um relogio entre store e decorator; isso reduz, mas nao
elimina, a divergencia, porque ainda existem duas leituras de relogio e a
truncagem de `EXPIREAT` continuava distinta da precisao do store.

Persistir o instante em precisao cheia (`to_f`) em vez de truncar para segundo
inteiro: escolhido para nao degradar a precisao viva so para casar com um formato
de log lossy. A alternativa rejeitada foi truncar o `expires_at` vivo para o
segundo; isso casaria os dois lados, mas fazendo a chave expirar antes do
combinado.

Unificar replay e execucao viva em `apply_durable`: escolhido para que "live ==
replay" seja o mesmo metodo, e nao duas copias que precisam concordar. A
alternativa rejeitada foi manter `AofLog#apply_record` separado; isso recriava a
duplicacao que o `CommandRegistry` existe para evitar. O replay passou a receber
um aplicador injetado, mantendo a infraestrutura como folha que so chama um metodo
do colaborador.

`fsync` configuravel, desligado por padrao: escolhido porque durabilidade forte e
throughput sao garantias diferentes, e o default preserva o comportamento atual. A
alternativa rejeitada foi ligar `fsync` sempre, o que tornaria cada append uma
escrita sincrona no disco sem o operador pedir.

`INFO` como gauges de keyspace em vez de contador de requests: escolhido porque
gauges saem do estado do store, sem seam transversal. A alternativa rejeitada foi
um contador de comandos agora; ele acoplaria o executor ao ponto de dispatch e
teria de ser deduplicado entre o decorator de AOF e o replay, entao foi adiado ate
existir um objeto de metricas que justifique o acoplamento.

Compaction a partir do estado vivo, com trigger no boot: escolhido porque reescrever
o log a partir do snapshot e a forma mais direta de limitar crescimento sem um
formato de snapshot separado. A alternativa rejeitada foi auto-compactar por razao
de crescimento em background; isso exigiria uma thread e contabilidade de tamanho
antes de a licao de "reescrever o estado minimo" estar clara.

Event loop single-threaded em vez de thread-por-cliente: escolhido porque e o
modelo que servidores de cache reais usam e porque ensina IO multiplexado de
verdade. As alternativas rejeitadas foram pool de threads (ainda bloqueia um
worker por cliente lento e adiciona uma fila antes da licao do reactor) e uma
lib async/nio4r (formato de producao, mas a gem esconderia a mecanica do
`IO.select` que o projeto quer ensinar). Thread-por-cliente nao foi apagado da
historia: o journal e os ADRs preservam por que ele existiu e por que saiu.

Contrato de protocolo incremental (`consume(buffer)`) em vez de bloqueante
(`read_request(io)`): escolhido porque um reactor recebe bytes parciais e nao pode
bloquear esperando um frame inteiro. A alternativa rejeitada foi manter
`read_request` como adaptador sobre `consume`; isso deixaria duas portas de
entrada e um caminho bloqueante morto. Consequencia semantica: um frame
incompleto agora e "preciso de mais bytes" (`nil`), nao um erro; so frame
malformado levanta `ProtocolError`.

Manter os mutexes das camadas internas mesmo com o servidor single-threaded:
escolhido porque a concorrencia e uma decisao da interface, nao do dominio nem da
aplicacao. A alternativa rejeitada foi remover os locks "ja que so ha uma thread";
isso acoplaria as camadas internas ao modelo do servidor e as quebraria se um
driver multi-thread voltasse. Com o event loop os locks ficam sem contencao, nao
errados.

Self-pipe para shutdown: escolhido porque `IO.select` bloqueia e precisa de algo
no conjunto de leitura para acordar quando `stop` vem de outra thread ou de um
sinal. A alternativa rejeitada foi um timeout curto no `select` em loop; isso
acordaria a toa muitas vezes por segundo so para checar uma flag.

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

Rastrear socket junto da thread deixa shutdown mais correto, mas aumenta o estado
mantido pelo servidor. A simplicidade ainda e aceitavel porque o estado tem dono
unico: `TcpServer`.

Decoder AOF estrito reduz tolerancia a corrupcao silenciosa, mas fixtures manuais
precisam ter tamanho correto. Isso e desejavel para ensinar recovery com framing
real.

Mutex de escrita unico no AofCommandExecutor deixa a durabilidade linearizavel,
mas serializa todas as escritas duraveis em um ponto so. Isso e coerente com a
filosofia de mutex unico do store e e aceitavel para estudo; sob escrita pesada
vira gargalo, como o resto do projeto. As leituras continuam concorrentes porque
ficam fora desse mutex.

Formatter sem heuristica fica menor e falha alto quando recebe algo que nao e
`Response`, o que e melhor para depurar contrato; em troca, ele deixa de aceitar
entradas avulsas que, de qualquer forma, nunca chegavam pela borda TCP.

Delete explicito custa duas linhas a mais que a versao compacta, mas paga isso
tornando a regra de expiracao visivel no ponto onde ela importa.

EXPIREAT em precisao cheia round-trip exatamente entre execucao e replay, mas
torna o registro um pouco maior (`1767268860.0` em vez de `1767268860`) e expoe
que a granularidade real do EXPIRE agora segue a precisao do relogio, nao o
segundo redondo.

`fsync` por append da durabilidade real contra queda de energia, mas troca
throughput por seguranca: cada escrita vira sincrona. Por isso fica desligado por
padrao e documentado como decisao do operador.

`INFO` por gauges e barato e nao acopla camadas, mas nao responde "quantos
comandos ja processei". Esse contador foi adiado de proposito; o journal registra
que a ausencia e uma escolha, nao um esquecimento.

Compaction encerra o crescimento do AOF e o arquivo novo reconstroi o mesmo estado,
mas e lossy por design: a historia de mutacoes some, ficando so o estado final. A
troca atomica por `rename` evita um arquivo meio-escrito se o processo cair durante
a reescrita.

Event loop single-threaded multiplexa muitos clientes em uma thread e nao cresce
threads com conexoes, mas exige parsing incremental, buffers de escrita e um
self-pipe de shutdown, e um comando CPU-bound trava o loop inteiro. Esse e o mesmo
trade do Redis: simplicidade de "uma coisa de cada vez" em troca de nao paralelizar
comandos.

Parsing incremental e binario-safe e robusto a fragmentacao TCP, mas e mais
codigo que o parser bloqueante: precisa de scanners que devolvem "incompleto" sem
consumir, em vez de simplesmente bloquear no socket ate o frame chegar.

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

A primeira correcao de null bulk escolheu simplicidade demais: retornar `[]`
fazia o executor responder `ERR unknown command`, mas isso ainda confundia comando
desconhecido com frame RESP malformado. A correcao final trocou a sentinela por
`ProtocolError`.

`TcpServer#stop` ainda deixava clientes ociosos bloqueados porque fechava apenas
o socket listener. A correcao passou a guardar `thread => socket`, fechar os
sockets ativos e so depois aguardar os workers.

O decoder AOF aceitava um frame cujo payload tinha um comando valido seguido de
bytes extras. Isso foi corrigido exigindo separadores entre argumentos e consumo
exato do payload.

O contrato entre comandos duraveis e replay estava correto para os comandos
atuais, mas dependia de leitura humana. Foi adicionado um teste que falha quando
um comando entra como duravel no registry sem cobertura de replay.

O `AofCommandExecutor` gravava o registro duravel e so depois aplicava a mutacao,
cada um sob o seu proprio mutex. Sob dois clientes concorrentes na mesma chave, o
cliente A podia gravar `SET key A`, perder a CPU antes de mutar, e o cliente B
gravar `SET key B` e mutar; quando A finalmente mutava, o store terminava em A
enquanto o AOF terminava em B. Apos um crash e replay, o estado recuperado
divergia do estado vivo. A correcao colocou append e mutacao no mesmo mutex de
escrita, restaurando a igualdade entre ordem do log e ordem de aplicacao.

O formatter textual ainda tinha um ramo de heuristica que decidia entre status e
bulk por regex (`simple_string?`), alem de ramos para `Integer` e para `to_s`
generico e uma recursao inalcancavel. Esse era exatamente o desenho que o commit
de tipos explicitos dizia ter substituido, mas o codigo morto continuava presente.
A correcao removeu os ramos inalcancaveis e manteve so o contrato real: `Response`
ou `nil`.

`Store#delete` chamava `live_entry_for(key)` e descartava o retorno. A chamada era
load-bearing: ela expira a chave antes do delete para que `DEL` em chave expirada
retorne 0. A correcao trocou para `return 0 if live_entry_for(key).nil?` e
adicionou um teste de caracterizacao para travar esse comportamento.

O help do `--aof` dizia "Accepted for future AOF support" mesmo com o AOF ligado
logo abaixo (replay no boot e decorator duravel). A correcao alinhou o texto ao
comportamento real.

O EXPIRE duravel tinha uma divergencia silenciosa: a execucao viva chamava
`store.expire(key, ttl)` (TTL relativo, float, relogio do store) enquanto o
registro persistia `EXPIREAT` absoluto truncado no relogio do decorator. O `.ceil`
do `TTL` mascarava a diferenca na maioria das consultas, mas em uma consulta dentro
da janela de truncamento o estado vivo via a chave viva e o estado reconstruido via
a chave expirada. A correcao fez o decorator resolver o registro uma vez e a
execucao viva aplicar esse mesmo registro, e persistir o instante em precisao cheia.

A correcao introduziu, de proposito, uma duplicacao temporaria: `apply_durable` no
executor e `apply_record` na infraestrutura faziam o mesmo mapeamento. O commit
seguinte removeu `apply_record` e fez o replay aplicar pelo mesmo `apply_durable`,
por injecao do aplicador, eliminando o risco de drift.

O contrato de protocolo `read_request(io)` assumia um IO bloqueante de onde dava
para puxar um frame inteiro. Isso e incompativel com um event loop, que recebe
bytes parciais. O contrato virou `consume(buffer)`, que parseia o que tem e
devolve "incompleto" sem consumir quando faltam bytes. Um efeito colateral
correto: no modelo antigo, fim de stream no meio de um bulk era erro; no modelo
incremental, isso e so "preciso de mais bytes", e o teste antigo que esperava erro
para bulk incompleto deu lugar a um teste que distingue incompleto (`nil`) de
malformado (terminador errado levanta `ProtocolError`).

O `TcpServer` de thread-por-cliente foi reescrito como reactor. O cleanup de
threads finalizadas, o gate de inicio de thread e o tracking `thread => socket`
das rodadas anteriores deixaram de existir porque nao ha mais threads de cliente.
Esses ajustes nao foram "perdidos": eles foram corretos para o modelo de threads e
o journal os preserva como historia. Dois testes de integracao que citavam threads
no nome foram renomeados para falar de conexoes, e um teste novo exercita um
comando que chega em dois segmentos TCP, provando o buffer por conexao.

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

Red: `test/unit/resp2_protocol_test.rb` passou a esperar `ProtocolError` para
null bulk em array de comando, e `test/integration/tcp_server_test.rb` passou a
esperar `-ERR protocol error\r\n` para esse payload RESP real.
Green: `Resp2Protocol#normalize_array` passou a levantar `ProtocolError` em vez
de fabricar `[]`.

Red: `test/integration/tcp_server_test.rb` adicionou um cliente ocioso e mostrou
que `stop` nao zerava o tracking.
Green: `TcpServer` passou a rastrear sockets ativos junto das threads, fechar
esses sockets em `stop` e so entao fazer `join`.

Red: `test/unit/aof_command_executor_test.rb` criou um frame AOF com bytes extras
apos um comando `SET` valido e mostrou que replay ainda aplicava o valor.
Green: `AofLog#decode` passou a exigir que o cursor consuma exatamente o payload
do frame.

Coverage: `test/unit/aof_command_executor_test.rb` passou a exercitar todos os
comandos que `CommandRegistry` marca como duraveis contra replay real. Esse teste
nao nasceu vermelho para o estado atual; ele existe para impedir drift na proxima
feature mutante.

Red: `test/unit/aof_command_executor_test.rb` ganhou um teste que estaciona o
primeiro escritor dentro do `append` (via um AOF de teste que bloqueia em um
`Queue`), deixa o segundo escritor completar e depois libera o primeiro. No codigo
antigo o store terminava com o valor do primeiro escritor enquanto o ultimo
registro do AOF era do segundo, falhando a invariante "ultimo registro duravel
reflete a ultima mutacao".
Green: `AofCommandExecutor` passou a fazer append e mutacao no mesmo
`@write_mutex`. O teste e deterministico no veredito: no codigo corrigido o segundo
escritor fica provadamente bloqueado no mutex enquanto o primeiro esta estacionado,
entao o `join(0.2)` expira e a ordem final fica consistente; no codigo antigo o
segundo escritor sempre completa antes da liberacao. O timeout afeta so a duracao,
nunca o resultado da assertiva.

Red: `test/unit/command_executor_test.rb` ganhou
`test_del_on_expired_key_reports_zero`. Ele nao nasceu vermelho contra o estado
atual; existe para impedir que uma futura limpeza do `delete` remova a expiracao
preguicosa sem ser notada.
Green: `Store#delete` ficou explicito sem mudar o comportamento observavel.

Red: `test_durable_expire_replays_to_the_exact_live_instant` faz `EXPIRE` num
relogio fracionario (`base + 0.7`), replica e consulta em `base + 60.3`, dentro da
janela onde o estado vivo (expira em `60.7`) e o reconstruido (expirava em `60.0`)
discordam. No codigo antigo o vivo respondia `"abc"` e o replay respondia `nil`.
Green: o decorator passou a aplicar o registro resolvido via `apply_durable` e o
`EXPIREAT` passou a precisao cheia, entao os dois lados aplicam o mesmo instante.

Red: `test_fsyncs_after_append_when_enabled` instancia `AofLog.new(path:, fsync: true)`
e quebra com keyword desconhecida; o par `test_flushes_without_fsync_by_default`
fixa o default (flush sem fsync). Ambos usam um stub artesanal de `File.open`,
porque o minitest 6 que o `autorun` carrega nao traz mais `minitest/mock`.
Green: `AofLog` ganhou o parametro `fsync:` e o `file.fsync if @fsync`.

Red: `test_info_reports_keyspace_summary` espera um bulk `keys:2\nkeys_with_expiry:1`
e falha com `:error` porque `INFO` ainda era comando desconhecido.
Green: `INFO` entrou no `CommandRegistry`, `Store#keyspace_summary` passou a contar
chaves vivas e `CommandExecutor#execute_info` formatou os gauges.

Red: `test_compact_rewrites_aof_to_minimal_replayable_state` faz seis comandos
duraveis redundantes, chama `compact` (inexistente) e verifica arquivo menor e
replay identico ao estado vivo.
Green: `Store#snapshot`, `AofLog#rewrite` (arquivo temporario + `rename` atomico) e
`AofCommandExecutor#compact` reescreveram o log a partir do estado minimo.

Red: os testes de `consume` foram escritos antes da reescrita do servidor:
`consume` devolvendo `[parts, rest]` para frame completo, `nil` para frame parcial,
preservando os bytes do proximo frame, e levantando `ProtocolError` para null bulk.
Eles falhavam porque `consume` ainda nao existia.
Green: `TextProtocol#consume` (linha terminada em `\n`) e `Resp2Protocol#consume`
(scanners cursor-based que devolvem incompleto sem consumir) passaram, ao lado dos
`read_request` antigos. Esse passo foi aditivo de proposito, para manter a suite
verde antes de trocar o servidor.

Green sem red explicito: a reescrita do `TcpServer` para event loop foi guiada
pelos testes de integracao ja existentes. Eles dirigem sockets TCP reais e nao
conhecem o modelo interno, entao passaram contra o reactor sem mudanca, provando que
o comportamento observavel foi preservado. O unico ajuste foi renomear dois testes
que citavam threads e adicionar um teste de comando fragmentado em dois segmentos.

Red: ao remover `read_request`, o `resp2_protocol_test` foi reescrito para o
contrato `consume`, incluindo um teste novo que separa frame incompleto (`nil`) de
frame malformado (terminador de bulk errado levanta `ProtocolError`).
Green: `read_request` e os scanners StringIO sairam; o servidor e a suite passaram a
depender so de `consume`.

## 8. Quais testes protegem quais decisoes

`test/unit/command_executor_test.rb` protege comando, aridade, TTL, que `DEL`
em chave expirada reporta 0 e que `INFO` reporta gauges de keyspace.

`test/unit/command_registry_test.rb` protege o contrato compartilhado entre
executor e AOF: nomes publicos, aridade, durabilidade e transformacao de
`EXPIRE` para `EXPIREAT`, alem do parsing de inteiro nao negativo.

`test/unit/text_protocol_test.rb` protege parsing, tipo de resposta e o `consume`
incremental por linha (frame completo, rest e frame ainda incompleto).

`test/unit/resp2_protocol_test.rb` protege o parser incremental e o formatter
RESP2: frame completo com rest, frame parcial como `nil`, bytes do proximo frame
preservados, null bulk em comando e terminador de bulk malformado como
`ProtocolError`.

`test/integration/tcp_server_test.rb` protege conexao TCP real e clientes
concorrentes no event loop, incluindo comando RESP2 real, erro RESP malformado
visivel ao cliente, comando fragmentado em dois segmentos TCP, remocao de conexoes
fechadas do tracking e shutdown que fecha clientes ociosos sem bloquear.

`test/unit/aof_command_executor_test.rb` protege AOF, replay, append antes de
mutacao, ignorar frame parcial, rejeitar frame com bytes extras, manter contrato
entre comandos duraveis e replay, serializar o registro duravel com a mutacao do
store sob escrita concorrente, o determinismo de EXPIRE entre vivo e replay, o
`fsync` opcional e a compaction que reescreve o log para o estado minimo
replayavel.

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
| `844d5b5` | Journal precisava preservar a limpeza de parsing | Registro cronologico do ajuste encontrado pela revisao | `bin/test`, `bin/check` |
| `a6646e3` | Null bulk RESP ainda passava pela aplicacao como `[]` | Adapter RESP trata null bulk em comando como `ProtocolError` | `ruby -Itest test/unit/resp2_protocol_test.rb`, `ruby -Itest test/integration/tcp_server_test.rb`, `bin/test`, `bin/check` |
| `d04dbb1` | Journal precisava registrar a melhoria de null bulk | Docs preservaram a sentinela antiga e a correcao final | `bin/test`, `bin/check` |
| `05a9349` | `stop` nao encerrava clientes ociosos | TCP passa a rastrear e fechar sockets ativos | `ruby -Itest test/integration/tcp_server_test.rb`, `bin/test`, `bin/check` |
| `7b3dc30` | AOF aceitava bytes extras no frame | Decoder exige consumo exato do payload | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `9fd849f` | Contrato duravel/replay dependia de revisao manual | Teste cobre todos os comandos duraveis publicos contra replay | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `2d6cb29` | Append e mutacao do AOF eram secoes criticas separadas | `AofCommandExecutor` serializa append e mutacao no mesmo mutex de escrita | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `6a0e3f9` | Formatter textual carregava heuristica morta | Remocao do fallback inalcancavel; formatter so trata `Response` ou `nil` | `bin/test`, `bin/check` |
| `079b998` | `delete` escondia expiracao preguicosa load-bearing | Intencao explicita no delete e teste de `DEL` em chave expirada | `ruby -Itest test/unit/command_executor_test.rb`, `bin/test`, `bin/check` |
| `f8c4be2` | Help do `--aof` dizia "future support" para recurso ativo | Texto de CLI alinhado ao comportamento real | `ruby -c bin/rediscraft`, `bin/test`, `bin/check` |
| `12400ca` | Toolchain pinada em Ruby 3.4.2 | Bump para 3.4.9 em `.ruby-version` e `.tool-versions` | `bin/check` |
| `d635ba3` | EXPIRE vivo divergia do replay (relogio duplo e truncagem) | Execucao viva aplica o registro persistido em precisao cheia | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `42fc1a7` | `apply_durable` e `apply_record` duplicavam o mapeamento | Replay aplica pelo mesmo `apply_durable` via aplicador injetado | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `29b0f85` | AOF so dava flush, sem garantia em disco | `fsync` opcional por append e flag `--fsync` | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `2150bd5` | Faltava qualquer observabilidade | Comando `INFO` com gauges de keyspace | `ruby -Itest test/unit/command_executor_test.rb`, `bin/test`, `bin/check` |
| `401f8e2` | AOF crescia sem limite | Compaction reescreve o log do estado vivo via `rename` atomico | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `f8acbe4` | Protocolos so liam por IO bloqueante | `consume(buffer)` incremental em texto e RESP2 | `ruby -Itest test/unit/resp2_protocol_test.rb`, `bin/test`, `bin/check` |
| `3f458b8` | Thread-por-cliente nao ensina multiplexacao | `TcpServer` virou reactor single-threaded com `IO.select` e self-pipe | `ruby -Itest test/integration/tcp_server_test.rb`, `bin/test`, `bin/check` |
| `f3ad2b5` | `read_request` bloqueante ficou morto | Removido o pull bloqueante; servidor e suite usam so `consume` | `ruby -Itest test/unit/resp2_protocol_test.rb`, `bin/test`, `bin/check` |
| `3f4f3e9` | Alegacoes de performance nunca foram medidas | Harness de benchmark (throughput, percentis, RSS) | `ruby benchmarks/bench.rb` |
| `d8a3784` | Nagle adicionava variancia de latencia | `TCP_NODELAY` nos sockets aceitos | `ruby benchmarks/bench.rb`, `bin/check` |
| `cbd2361` | `INFO` era O(N) e travava o loop single-threaded | Contadores fisicos incrementais tornam `INFO` O(1) | `ruby -Itest test/unit/command_executor_test.rb`, `bin/check` |
| `a9fb0f8` | Entrada de diretorio nao era duravel sem fsync do dir | `fsync` de diretorio apos criar e apos `rename` | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/check` |
| `4628077` | Durabilidade alegada nunca foi testada contra crash | Teste sobe, mata com SIGKILL e recupera pelo AOF | `ruby -Itest test/integration/crash_recovery_test.rb`, `bin/check` |
| `cf2aa46` | Cliente que nao le faria o buffer crescer sem limite | Cap no backlog de escrita e drop da conexao | `ruby -Itest test/integration/tcp_server_test.rb`, `bin/check` |
| `46a3885` | Chave com TTL nunca lida vazava memoria | Ciclo de expiracao ativa limitado por amostra | `ruby -Itest test/unit/command_executor_test.rb`, `bin/check` |
| `c097128` | Expiracao ativa precisava rodar sob carga | Cron tick a ~10Hz no event loop | `ruby -Itest test/integration/tcp_server_test.rb`, `bin/check` |
| `d39df76` | Testes deterministicos nao cobriam entrada arbitraria | Fuzz afirma totalidade de `consume` em 20k inputs | `ruby -Itest test/unit/resp2_protocol_test.rb`, `bin/check` |
| `e15b212` | So existia o tipo string | Listas (`LPUSH`/`RPUSH`/`LLEN`/`LRANGE`) com tipo, `WRONGTYPE` e durabilidade | `ruby -Itest test/unit/command_executor_test.rb`, `bin/check` |
| `f3de935` | Faltava formatar arrays no fio | `:array` formatado em RESP2 e no protocolo textual | `ruby -Itest test/integration/tcp_server_test.rb`, `bin/check` |

## 10. Checklist de boundaries para futuras features

- Regra de existencia ou expiracao entra em `Domain::Store`.
- Validacao de comando entra em `Application::CommandExecutor`.
- Persistencia entra em `Infrastructure`.
- Parsing e formato de resposta entram em `Interface`.
- Novo protocolo deve implementar `consume(buffer)` e `format(response)` sem
  mudar dominio ou aplicacao.
- Novo comando publico deve entrar em `CommandRegistry` antes de executor,
  protocolo ou AOF.
- Novo parser de protocolo deve diferenciar frame incompleto (`nil`, espera mais
  bytes) de frame malformado (`ProtocolError`).
- O modelo de concorrencia vive so na interface; dominio e aplicacao nao devem
  assumir quantas threads dirigem o servidor.
- Novo comando duravel deve atualizar o teste de contrato entre registry, AOF e
  replay.
- Shutdown de interface externa deve liberar sockets e threads que ela abriu.
- Nova operacao duravel deve gravar o registro e aplicar a mutacao sob o mesmo
  mutex de escrita, para que a ordem do log seja a ordem de aplicacao.
- Execucao viva e replay de um comando duravel devem passar pelo mesmo aplicador
  (`apply_durable`), para que estado vivo e estado reconstruido nunca divirjam.
- Comando duravel novo precisa ser reconstruivel a partir do `snapshot`, senao a
  compaction perde a chave ao reescrever o log.
- Observabilidade comeca por gauge derivado do estado; um contador de requests so
  entra quando existir um objeto de metricas que justifique acoplar o dispatch.
- Teste unitario vem antes de adapter externo.

## 11. Como adicionar a proxima feature

`INFO` ja existe, mas so com gauges de keyspace. O proximo passo natural de
observabilidade e um contador de comandos: primeiro crie um objeto de metricas com
incremento thread-safe, decida onde incrementar uma unica vez por comando (o ponto
de dispatch da interface, nao o `apply_durable` que tambem roda no replay), injete
esse objeto no executor e no servidor, e so entao adicione o campo no `INFO`. O
journal deve registrar por que o gauge veio antes do contador.

## 12. Limites de producao deixados fora

Sem auth, TLS, ACL, RESP completo, snapshots binarios, replicacao, clustering,
limite de conexoes, `maxmemory` com eviction, tipos alem de string e listas
(hashes, sets, sorted sets), metricas completas (Prometheus/tracing),
auto-compaction por razao de crescimento e paralelismo de comandos (o event loop e single-threaded, como o Redis
classico: um comando CPU-bound trava o loop). Ja existem, em forma de estudo: event
loop com `IO.select` e cron, `fsync` opcional com `fsync` de diretorio, compaction
manual, `INFO` O(1), expiracao ativa, limite de buffer de escrita por conexao,
`TCP_NODELAY`, um harness de benchmark e um fuzz do parser.

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

Rodada atual de revisao Ruby/termonuclear encontrou quatro ajustes no escopo:
contrato de comandos duplicado entre executor e AOF, erro RESP confundido com
EOF, parsing de inteiro nao negativo duplicado e null bulk ainda representado por
`[]` antes de chamar a aplicacao. Todos foram corrigidos em commits atomicos.

Passada final depois das correcoes anteriores: sem achados bloqueantes ou nao
bloqueantes relevantes para aquele escopo. Evidencia: `bin/test` e `bin/check`
verdes com 34 testes e 80 assertions. Riscos residuais continuavam intencionais:
sem auth, TLS, limite de conexoes, backpressure, `fsync` configuravel, snapshots,
replicacao ou benchmarks de contencao.

Nova revisao Ruby/termonuclear encontrou tres ajustes: shutdown TCP nao fechava
clientes ociosos, decoder AOF aceitava bytes extras no frame e faltava teste de
contrato entre comandos duraveis e replay. Todos foram corrigidos. Evidencia:
`bin/test` e `bin/check` verdes com 37 testes e 90 assertions.

Nova rodada de revisao Ruby/termonuclear focada em concorrencia e limpeza
encontrou quatro ajustes: append e mutacao do AOF em secoes criticas separadas
(risco de divergencia entre log e estado vivo), heuristica morta no formatter
textual, expiracao preguicosa load-bearing escondida em `delete` e help de CLI
desatualizado. Todos foram corrigidos em commits atomicos. Evidencia: `bin/test`
e `bin/check` verdes com 39 testes e 92 assertions. O risco mais grave dessa
rodada era de durabilidade sob concorrencia, nao de throughput; os riscos
residuais conhecidos continuam intencionais (sem auth, TLS, limite de conexoes,
backpressure, `fsync` configuravel, snapshots, replicacao ou benchmarks de
contencao).

Rodada de evolucao dirigida (nao mais so revisao): subiu o Ruby para 3.4.9 e
implementou quatro itens antes documentados como fora de escopo. EXPIRE virou
deterministico entre execucao e replay; `fsync` ficou configuravel; `INFO` passou
a expor gauges de keyspace; e a compaction passou a reescrever o AOF a partir do
estado vivo. Evidencia: `bin/test` e `bin/check` verdes com 44 testes e 108
assertions. A secao 15 detalha cada decisao em nivel de especialista. Os riscos
residuais que continuam fora: auth, TLS, RESP completo, replicacao, clustering,
limite de conexoes, metricas completas e auto-compaction.

Rodada de mudanca de direcao arquitetural: trocar thread-por-cliente por um event
loop single-threaded. Tres commits de codigo (parsing incremental aditivo,
reescrita do `TcpServer` como reactor, remocao do `read_request` morto) mais ADR
0004 e docs. O contrato de protocolo virou `consume(buffer)` incremental. Os locks
internos ficaram de proposito, porque a concorrencia e uma decisao da interface.
Evidencia: `bin/test` e `bin/check` verdes com 49 testes e 116 assertions, e um
smoke test do processo real (texto e AOF). A secao 16 ensina a transicao em
detalhe. Risco residual assumido: um comando CPU-bound trava o loop, o mesmo trade
do Redis classico.

Rodada de performance, durabilidade e limites: a primeira que mediu antes de
afirmar. Trouxe um harness de benchmark, e o benchmark imediatamente provou a
alegacao antiga de que um comando O(N) trava o loop (`INFO` derrubava 3x o
throughput), que foi entao consertada (contadores O(1)) e re-medida. Fechou tambem a
escada de durabilidade (`fsync` de diretorio) com um teste de crash de processo real,
o limite de buffer de escrita contra cliente lento, a expiracao ativa contra
vazamento de memoria, e um fuzz que afirma totalidade do parser. Em paralelo, o
journal ganhou um primer conceitual no topo (secao 2) e a secao 17 sobre a GVL, para
que a primeira leitura ensine os conceitos, nao so o historico. Evidencia: `bin/test`
e `bin/check` verdes com 55 testes e 3522 assertions, mais numeros reais em
`benchmarks/baseline.md`. As secoes 17 e 18 detalham cada decisao. Limites que
continuam fora e agora explicitos: `maxmemory`/eviction, tipos alem de string e
replicacao.

Importante: o journal deve preservar que as decisoes iniciais existiram e foram
melhoradas. As secoes acima usam "primeiro" e "depois da revisao" de proposito:
o objetivo nao e apresentar uma arquitetura perfeita desde o inicio, mas mostrar
como testes e revisoes mudaram o desenho.

## 14. Nota tecnica detalhada: rodada de serializacao AOF e limpeza

Esta secao registra, em nivel de especialista, o que cada mudanca dessa rodada
fez e por que. Ela aprofunda o que as secoes anteriores resumem.

### 14.1 Serializacao do registro duravel com a mutacao (flagship)

O modelo de durabilidade do Rediscraft e write-ahead: o `AofCommandExecutor`
grava o registro duravel antes de aplicar a mutacao no store, para que uma falha
no arquivo nao deixe o store adiantado em relacao ao log. Essa decisao continua
valida. O problema era outro: a granularidade do lock.

Antes, `execute` fazia duas operacoes atomicas independentes:

1. `@aof.append(durable_parts)` — atomica sob o mutex do `AofLog`.
2. `@inner.execute(parts)` — atomica sob o mutex do `Store`.

Cada operacao era atomica em si, mas o par nao era. Entre o passo 1 e o passo 2
de um cliente, outro cliente podia executar o par inteiro. A ordem do AOF passa a
ser decidida no passo 1 (quem pega o mutex do `AofLog` primeiro) e a ordem do
store no passo 2 (quem pega o mutex do `Store` primeiro). Nada forca essas duas
ordens a coincidir.

Trace do bug, dois clientes na chave `key`:

- A: append `SET key A` (AOF = [A]); perde a CPU antes de mutar.
- B: append `SET key B` (AOF = [A, B]); muta (store = B); termina.
- A: muta (store = A); termina.

Estado vivo final = A. Replay do AOF aplica A depois B = B. Divergencia: um crash
logo apos esse ponto recupera B, mas A foi confirmado por ultimo no estado vivo.
Isso quebra a propriedade que o AOF existe para garantir: o log deve ser uma
serializacao das mutacoes na ordem em que elas realmente aconteceram.

A correcao coloca append e mutacao no mesmo `@write_mutex` dentro do
`AofCommandExecutor`. Com isso, o par vira um unico ponto de linearizacao: entre
o append e a mutacao de um escritor, nenhum outro escritor pode appendar nem
mutar. A ordem do log passa a ser, por construcao, a ordem de aplicacao.

Tres detalhes de desenho importam:

- Ordem de locks. `@write_mutex` e sempre o mais externo; os mutexes do `Store` e
  do `AofLog` sao folhas adquiridas dentro dele. Nenhum codigo adquire
  `@write_mutex` segurando um mutex folha, entao nao ha ciclo e nao ha deadlock.
- Leituras ficam fora. `GET`, `TTL` e `EXISTS` nao produzem registro duravel,
  entao `durable_parts` e `nil` e o caminho retorna antes do `@write_mutex`. Uma
  leitura pode observar o estado entre o append e a mutacao de uma escrita, mas
  isso e inofensivo: leituras nao entram no log e nao reordenam o historico. Nao
  serializar leituras preserva a concorrencia de leitura que o projeto ja tinha.
- Por que o Redis nao precisa disso. O Redis e single-threaded no loop de
  eventos: executar o comando e propagar para AOF/replicacao acontecem no mesmo
  tick, sem outro comando no meio. O `@write_mutex` reconstroi, em um servidor
  thread-por-cliente, a mesma atomicidade que o loop unico do Redis da de graca.

O teste e deterministico no veredito apesar de exercitar uma corrida. Ele
estaciona o primeiro escritor dentro do `append` segurando um `Queue`, deixa o
segundo escritor rodar e so entao libera o primeiro. No codigo antigo o segundo
escritor sempre completa (nao ha lock que o segure) e a invariante "ultimo
registro duravel == ultima mutacao" falha. No codigo corrigido o segundo escritor
fica bloqueado no `@write_mutex` enquanto o primeiro esta estacionado; o
`join(0.2)` expira, o primeiro e liberado e a ordem final fica consistente. O
timeout muda a duracao do teste, nunca o resultado da assertiva.

### 14.2 Formatter textual sem heuristica

O commit que introduziu tipos de resposta explicitos em `Response` dizia ter
substituido a heuristica que decidia entre status e bulk por regex. Na pratica, o
codigo novo foi adicionado e o antigo nao foi removido: `format` ainda tinha um
ramo `simple_string?`, um ramo para `Integer`, um ramo `to_s` generico e uma
recursao que nunca era alcancada (os quatro `kind` possiveis ja eram tratados
acima dela). Como a borda TCP sempre passa um `Response` ou `nil`, todo esse
bloco era inalcancavel.

Codigo morto inalcancavel e pior que inofensivo: ele sugere um contrato que nao
existe e, neste caso, transformava uma violacao de contrato em string silenciosa.
A correcao deixou `format` tratando apenas `Response` e `nil`. Se um nao-Response
chegar, `format` agora levanta `NoMethodError` em vez de inventar uma resposta;
falhar alto e o comportamento desejado para um bug de contrato.

### 14.3 Expiracao preguicosa explicita em delete

`Store#delete` chamava `live_entry_for(key)` e ignorava o retorno. A chamada
parece removivel, mas e load-bearing: `live_entry_for` aplica a expiracao
preguicosa, removendo a chave se ela ja expirou. Sem ela, `DEL` em uma chave
expirada removeria a entrada fisica ainda presente e responderia 1, quando o
contrato publico e responder 0 (a chave ja nao existia). A correcao trocou a linha
muda por `return 0 if live_entry_for(key).nil?`, que torna a fronteira de
expiracao visivel e fica igual ao estilo de `expire_at` e `persist`. Um teste de
caracterizacao (`DEL` em chave expirada retorna 0) trava o comportamento contra
futuras limpezas.

### 14.4 Help de CLI alinhado ao comportamento

O `--aof PATH` descrevia "Accepted for future AOF support", mas o `bin/rediscraft`
ja faz replay no boot e embrulha o executor com o decorator duravel quando a flag
e passada. Texto de help e saida operacional: prometer "future" para um recurso
ativo desinforma quem opera o servidor. A correcao alinhou o texto ao
comportamento real.

## 15. Nota tecnica detalhada: rodada de durabilidade e observabilidade

Esta secao explica, como um especialista em Ruby explicaria a um colega, o que
mudou em cada item desta rodada e as nuances que pesaram em cada decisao.

### 15.1 Ruby 3.4.9

A toolchain estava pinada em 3.4.2 (`.ruby-version` e `.tool-versions`). Subir para
3.4.9 e um bump de patch dentro do mesmo minor: ganha correcoes sem risco de
mudanca de linguagem. Mantive o CI em `ruby-version: "3.4"`, que ja resolve para o
patch mais novo, e nao saltei para 4.0 de proposito: 4.0 nao esta no asdf da
maquina e um salto de major pediria validar mudancas de comportamento antes. A
licao operacional: o pin exato vive no projeto; o CI pode flutuar no minor.

### 15.2 EXPIRE deterministico entre execucao e replay

Este foi o item com mais nuance, entao vale o detalhe.

O problema. O AOF persiste mutacoes para que o replay reconstrua o estado. Para
SET e DEL isso e trivial: o registro e o proprio comando. EXPIRE e diferente
porque carrega tempo. A execucao viva chamava `store.expire(key, ttl)`, que
calcula `now + ttl` com o relogio do `Store` e guarda um `Time` em precisao de
ponto flutuante. O registro duravel, porem, era `EXPIREAT (clock.call + ttl).to_i`,
calculado com o relogio do `AofCommandExecutor` e truncado para segundo inteiro.
Tres fontes de divergencia: dois relogios distintos, dois instantes de leitura, e
duas precisoes (float vivo contra inteiro persistido).

Por que quase nunca aparecia. `Store#ttl` faz `(expires_at - now).ceil`. O `ceil`
costuma reabsorver a diferenca de fracao de segundo, entao a consulta de TTL
devolvia o mesmo numero nos dois lados. O bug so fica observavel quando a consulta
cai dentro da janela entre os dois instantes. O teste arma exatamente isso: EXPIRE
em `base + 0.7`, com vida de 60s; o vivo expira em `60.7`, o registro trunca para
`60.0`; consultando em `base + 60.3`, o vivo ainda ve a chave e o replay ja a
expirou.

A correcao. O caminho duravel agora resolve o registro uma unica vez no decorator
e a execucao viva aplica esse mesmo registro, via `apply_durable`. Como o registro
e o mesmo objeto-string que sera relido no replay, os dois lados aplicam o instante
identico. E persisti o instante em precisao cheia (`to_f`, ex.: `1767268860.0`) em
vez de truncar para o segundo. A alternativa de truncar o vivo tambem casaria os
lados, mas fazendo a chave morrer antes do combinado; preferi nao degradar a
precisao viva para acomodar um formato de log lossy.

Por que aplicar o registro em vez de reexecutar o comando. Reexecutar `EXPIRE`
relativo no inner reintroduziria a segunda leitura de relogio. Aplicar o
`EXPIREAT` ja resolvido garante uma leitura so. `EXPIREAT` continua sem ser comando
publico: ele so existe como registro interno, aplicado por `apply_durable`, que o
cliente nunca alcanca pelo `execute`.

Unificacao com o replay. A primeira versao da correcao deixou `apply_durable` no
executor e `apply_record` na infraestrutura fazendo o mesmo mapeamento, uma
duplicacao que o projeto combate desde o `CommandRegistry`. O commit seguinte fez
o replay receber um aplicador injetado e aplicar pelo mesmo `apply_durable`. Agora
"live == replay" nao e um cuidado de codificacao, e o mesmo metodo. A infra
continua folha: o `AofLog` so chama `applicator.apply_durable(record)`, sem
conhecer a classe concreta.

### 15.3 fsync configuravel

`file.flush` move o buffer do Ruby para o kernel, mas os bytes ainda podem viver na
page cache do SO; uma queda de energia os perde. `file.fsync` forca a descida para
o disco. Sao garantias diferentes, com custos diferentes: `fsync` por append torna
cada escrita uma operacao sincrona de disco. Por isso a opcao entra desligada por
padrao, preservando o comportamento e o throughput atuais, e fica como decisao
explicita do operador via `--fsync`.

Nota de teste. O minitest 6 que o `autorun` carrega nesta maquina nao traz mais
`minitest/mock`, entao o `File.stub` nao existe. Como o projeto nunca dependeu de
gem de mock, escrevi um stub artesanal que troca `File.open` por um arquivo-espiao
durante o bloco e restaura depois. E mais codigo que um mock pronto, mas mantem a
suite sem dependencias novas e ensina que stub e so substituicao temporaria de
metodo com restauracao garantida no `ensure`.

### 15.4 INFO por gauges, e por que nao um contador ainda

`INFO` expoe `keys` e `keys_with_expiry`, lidos do estado vivo do store em uma
unica passada sob o mutex, excluindo chaves logicamente expiradas. Sao gauges:
fotos do estado, sem historia.

A decisao interessante e o que ficou de fora. O contador classico de observabilidade
e "comandos processados". Ele parece simples, mas nao tem um lar limpo neste
desenho. No modo sem AOF, todo comando passa por `CommandExecutor#execute`. No modo
com AOF, os comandos duraveis passam por `apply_durable` (nao por `execute`), e o
mesmo `apply_durable` roda no replay. Contar dentro do executor ou contaria duas
vezes, ou contaria o replay como se fosse trafego de cliente. O lugar correto e o
ponto de dispatch da interface, que so ve comandos de cliente, com um objeto de
metricas compartilhado que o `INFO` leria. Como isso acopla executor e servidor por
um objeto novo, adiei: gauge agora, contador quando o objeto de metricas se
justificar. O journal registra essa ausencia como escolha, nao esquecimento.

### 15.5 Compaction a partir do estado vivo

O AOF e um log de append: ele cresce a cada comando duravel, inclusive os que se
anulam (cem SET na mesma chave, ou SET seguido de DEL). Compaction reescreve o log
no menor conjunto de registros que reconstroi o estado atual.

O algoritmo. `Store#snapshot` devolve as entradas vivas com valor e expiracao.
`AofCommandExecutor#compact` mapeia cada entrada para os registros minimos: sempre
um `SET`, e um `EXPIREAT` se houver expiracao. E o inverso exato de `apply_durable`,
entao o arquivo compactado replica para o mesmo estado.

Atomicidade em duas dimensoes. Primeiro contra concorrencia: a compaction segura o
mesmo `@write_mutex` das escritas, entao o snapshot e a reescrita formam um ponto
unico em que nenhuma escrita duravel se intromete; sem isso, um SET entre o snapshot
e o `rename` sumiria. Segundo contra falha de processo: `AofLog#rewrite` escreve um
arquivo `.tmp` e troca por `File.rename`, que e atomico no mesmo filesystem. Se o
processo cair no meio da escrita, o `@path` original continua intacto; nunca existe
um AOF meio-reescrito.

O custo honesto. Compaction e lossy por design: a historia de mutacoes desaparece,
fica so o estado final. Por isso o trigger atual e explicito (`--compact-on-start`,
depois do replay) e nao automatico; auto-compaction por razao de crescimento pediria
uma thread de fundo e contabilidade de tamanho, que ficam para quando a licao basica
de "reescrever o estado minimo" ja estiver firme.

## 16. Nota tecnica detalhada: de thread-por-cliente para event loop

Esta secao ensina a maior mudanca de direcao do projeto. Ela e longa de proposito:
o objetivo nao e so dizer o que mudou, mas mostrar por que cada peca do reactor
existe e o que ela substituiu. Trate como um especialista explicando a um colega
por que vale trocar o modelo que ja funcionava.

### 16.1 Por que sair do thread-por-cliente

O servidor antigo era o modelo mais facil de ler: para cada conexao aceita, uma
`Thread.new` rodava `handle_client`, que ficava em loop chamando
`protocol.read_request(io)`. Esse `read_request` fazia `io.gets`/`io.read`
bloqueantes: a thread parava ali ate o cliente mandar um frame inteiro.

Esse modelo ensina pouco sobre como servidores de cache reais funcionam e tem tres
custos concretos. Primeiro, escala threads com conexoes: mil clientes ociosos sao
mil threads paradas, cada uma com sua pilha. Segundo, um cliente lento prende uma
thread inteira bloqueada na leitura. Terceiro, e justamente o que o Redis nao faz:
o Redis e single-threaded num event loop, e parte do valor didatico do projeto e
chegar nesse modelo de proposito, depois de o aluno ja ter visto a versao com
threads e sentido seus limites.

A decisao de trocar nao apaga a versao com threads. O ADR 0004 e este journal
preservam por que ela existiu. O ponto pedagogico do repositorio nunca foi "a
arquitetura certa desde o inicio", e sim "como o desenho evolui quando voce o
empurra para mais perto do real".

### 16.2 O reactor, peca por peca

O novo `TcpServer` e um reactor: uma unica thread roda um loop em volta de
`IO.select`. Cada iteracao monta tres conjuntos e bloqueia ate algo ficar pronto.

O conjunto de leitura tem o socket listener, um self-pipe de shutdown e todos os
sockets de cliente. Se o listener fica pronto, ha uma conexao nova para aceitar. Se
um socket de cliente fica pronto, ha bytes para ler. Se o self-pipe fica pronto, e
hora de desligar.

O conjunto de escrita tem so os sockets que ainda tem bytes pendentes no seu buffer
de escrita. Isso e importante: nao adianta perguntar ao `select` "esse socket pode
escrever?" se nao ha nada para mandar; so registramos para escrita quem tem backlog.

Sockets sao nao bloqueantes. `accept_nonblock`, `read_nonblock` e `write_nonblock`
nunca param a thread: se nao ha o que fazer agora, levantam `IO::WaitReadable` ou
`IO::WaitWritable`, que o reactor trata como "volta no proximo `select`". Uma unica
thread, portanto, atende todos os clientes intercalando pedacos de trabalho.

### 16.3 Buffers por conexao, porque TCP nao tem frames

A consequencia mais importante de largar a leitura bloqueante e que o protocolo
nao pode mais assumir que um `read` traz um comando inteiro. TCP e um stream de
bytes sem fronteiras: um `SET` pode chegar em dois segmentos (`"SET na"` e depois
`"me Ada\n"`), e dois comandos podem chegar grudados num segmento so.

Por isso cada `Connection` carrega um `read_buffer`. Ao ler, o reactor anexa os
bytes novos ao buffer e tenta extrair quantos frames completos houver, em loop. A
extracao e o novo contrato de protocolo: `consume(buffer)`. Ele devolve
`[parts, rest]` quando ha um frame completo (e `rest` sao os bytes que sobraram,
que voltam para o buffer), `nil` quando ainda faltam bytes, e levanta
`ProtocolError` quando o frame esta malformado.

Essa e a diferenca semantica que merece atencao. No modelo bloqueante, ficar sem
bytes no meio de um bulk era erro, porque a unica forma de "faltar byte" era o
stream acabar. No modelo incremental, faltar byte e o caso normal: e so esperar o
proximo `read`. Entao "incompleto" virou `nil`, e so a corrupcao real (prefixo
desconhecido, terminador de bulk errado, null bulk dentro de um comando) levanta
`ProtocolError`. O teste antigo que esperava erro para bulk incompleto deu lugar a
um teste que separa explicitamente os dois casos.

O parser RESP incremental usa scanners cursor-based: `scan_value`, `scan_array`,
`scan_bulk`, `scan_line`. Cada um recebe `(buffer, cursor)` e devolve
`[valor, proximo_cursor]` ou um sentinela `INCOMPLETE`. Um array so e completo se
todos os seus elementos forem completos; se qualquer elemento faltar bytes, o array
inteiro volta `INCOMPLETE` e nada e consumido. Reparsear do inicio a cada chegada de
bytes e O(tamanho do frame), aceitavel para estudo e bem mais simples que uma
maquina de estados que retoma de onde parou.

### 16.4 Escrita tambem pode bloquear

Simetricamente, `write_nonblock` pode escrever so parte do buffer quando o buffer de
socket do SO esta cheio, levantando `IO::WaitWritable`. Por isso cada conexao tem um
`write_buffer`: o reactor enfileira a resposta, tenta esvaziar o que der agora, e o
que sobrar fica para a proxima vez que o `select` disser que aquele socket aceita
escrita. Sem esse cuidado, um cliente que nao le rapido faria a escrita do servidor
falhar ou bloquear.

`QUIT` e erro de protocolo usam um campo `close_after_flush`: a resposta (o `+OK` do
QUIT, ou o `-ERR protocol error`) e enfileirada, e a conexao so e fechada depois que
o buffer de escrita esvazia. Fechar antes perderia a ultima resposta.

### 16.5 Shutdown com self-pipe

`IO.select` bloqueia. Como acordar o loop quando `stop` vem de outra thread (o
harness de teste) ou de um sinal (`SIGINT`)? A resposta classica e o self-pipe: no
`start`, o servidor cria um par `IO.pipe` e poe a ponta de leitura no conjunto de
leitura do `select`. `stop` so escreve um byte na ponta de escrita. Isso faz o
`select` retornar imediatamente; o loop ve que o self-pipe ficou legivel e sai.

Repare na divisao de trabalho: `stop` nao fecha sockets nem mexe em estrutura
compartilhada. Ele so acorda o loop. Quem fecha tudo e a propria thread do loop, no
`ensure` do `start`. Isso evita corrida: uma so thread e dona dos sockets e do mapa
de conexoes. A unica coordenacao entre threads e o self-pipe (a escrita/leitura do
pipe ja da o happens-before) e um pequeno mutex que protege o mapa de conexoes para
o `tracked_client_count`, que o teste le de fora.

### 16.6 Por que os locks internos continuam

Esta e a decisao mais sutil da rodada, e a que mais ensina sobre fronteiras. Com o
servidor single-threaded, o `@write_mutex` do `AofCommandExecutor` e o mutex do
`Store` passam a ser sempre sem contencao: so existe uma thread executando comandos.
A tentacao e remove-los "ja que nao ha concorrencia".

Nao removi, e a razao e de camadas. O modelo de concorrencia e uma decisao da
interface, nao do dominio nem da aplicacao. Se o `Store` e o `AofCommandExecutor`
removessem seus locks assumindo "o servidor e single-threaded", eles passariam a
depender de um detalhe da borda. No dia em que alguem dirigir a aplicacao por outro
driver (um pool de threads, um teste concorrente, um segundo event loop por shard),
as camadas internas estariam silenciosamente erradas. Mantendo os locks, o dominio e
a aplicacao continuam corretos sob qualquer driver; com o event loop atual eles
ficam apenas sem contencao, o que e barato. A licao: uma mudanca de concorrencia
bem-feita fica contida na camada que a decide.

Isso tambem explica por que o teste da rodada passada,
`test_serializes_durable_record_with_store_mutation`, continua valido. Ele protege
uma invariante da camada de aplicacao (append e mutacao como um ponto unico), nao do
servidor. Trocar o servidor nao mexe nessa invariante.

### 16.7 Como os testes guiaram a troca sem regressao

A reescrita do servidor nao teve um teste vermelho proprio, e isso foi de proposito.
Os testes de integracao existentes ja dirigem sockets TCP reais (`PING`, `SET`,
`GET`, `QUIT`, cinco clientes concorrentes, um comando RESP2 real, um erro de
protocolo visivel) e nao conhecem o modelo interno do servidor. Eles foram a rede de
seguranca: se passassem contra o reactor sem mudanca, o comportamento observavel
estava preservado. Passaram. O unico ajuste foi de honestidade: dois testes citavam
"thread" no nome para algo que agora e conexao, entao foram renomeados, e adicionei
um teste que escreve um comando em dois pedacos com uma pausa no meio, exercitando o
buffer por conexao que o modelo antigo nem precisava.

O parsing incremental, esse sim, veio primeiro como `consume` aditivo e testado, com
a suite verde, antes de o servidor passar a depender dele. So depois que o reactor
estava verde o `read_request` bloqueante foi removido. Essa ordem (adicionar o novo,
migrar, remover o velho) manteve cada commit verde e atomico, em vez de um salto
unico arriscado.

### 16.8 O que continua valendo o trade

O reactor herda o trade do Redis: uma so thread significa "uma coisa de cada vez".
Um comando CPU-bound trava o loop inteiro, porque nao ha outra thread para tocar os
demais clientes. Para um cache, onde os comandos sao curtos, esse trade compra
simplicidade enorme: nenhum lock no caminho de execucao de comando, nenhuma corrida
entre comandos, ordem total natural. Quando o projeto quiser escalar, o caminho nao
e voltar a thread-por-cliente, e sim medir o custo por comando e, se preciso, rodar
varios event loops por shard, cada um dono do seu pedaco do keyspace.

## 17. Nota tecnica detalhada: concorrencia em Ruby e a GVL

Varias decisoes deste projeto dependem do modelo de memoria do Ruby, mas o journal
ate aqui o assumia. Esta secao o torna explicito, porque sem ele as licoes de
concorrencia nao se reproduzem.

### 17.1 O que a GVL e

MRI (o Ruby de referencia) tem uma Global VM Lock: so uma thread executa bytecode
Ruby por vez. Isso engana muita gente para "entao nao preciso de lock". A conclusao
e falsa, e o ADR 0002 ja dizia "threads podem intercalar mesmo com a GVL" sem
explicar por que. O porque e: a GVL serializa *bytecode*, nao *operacoes de alto
nivel*. Um `@contador += 1` ou um `@entries[chave] = valor` seguido de um
`@key_count += 1` sao varios bytecodes. A GVL pode ser liberada entre eles, e outra
thread roda no meio.

### 17.2 Quando a GVL e liberada

A GVL e liberada em operacoes bloqueantes: IO (`IO.select`, ler de socket,
`File#fsync`), `sleep`, e em pontos de checagem do escalonador. Entao uma thread que
faz `@aof.append(...)` (que escreve em arquivo) libera a GVL durante o IO; outra
thread acorda e roda. Foi exatamente o buraco do bug de serializacao da secao 14:
entre `append` e a mutacao do store, o `append` faz IO, solta a GVL, e o outro
escritor se intromete. A GVL nao protegia o par; so um lock que cobre os dois passos
protege.

### 17.3 Visibilidade de memoria

Alem de atomicidade, ha visibilidade: uma escrita feita por uma thread precisa ser
vista por outra. Em MRI, adquirir e liberar a GVL (e um `Mutex`) funciona como
barreira de memoria: o que foi escrito antes de liberar fica visivel para quem
adquire depois. E por isso que dois mecanismos deste servidor funcionam sem mais
cerimonia: o `tracked_client_count`, lido pela thread de teste sob o mesmo mutex que
a thread do loop usa para mutar `@connections`; e o self-pipe de shutdown, em que a
escrita no pipe por uma thread e a leitura pela outra estabelecem o happens-before
via IO. Sem essas barreiras, uma flag simples poderia nunca ser observada como
mudada pela outra thread.

### 17.4 Por que os locks continuam mesmo com o event loop

Com o servidor single-threaded, nenhuma das condicoes acima se aplica ao caminho de
comando: ha uma thread so. Entao o mutex do `Store` e o `@write_mutex` ficam sem
contencao. A tentacao de remove-los e real, e a recusa tem duas razoes. A primeira,
de camadas, ja esta na secao 16: concorrencia e decisao da interface. A segunda e de
portabilidade: a GVL e detalhe de implementacao do MRI. Em JRuby ou TruffleRuby nao
existe GVL, e threads rodam bytecode Ruby em paralelo de verdade. Ali os mutexes do
dominio deixam de ser seguro ocioso e voltam a ser load-bearing. Manter os locks
deixa o dominio e a aplicacao corretos em qualquer runtime e sob qualquer driver; e
um custo quase zero por uma corretude que nao depende de uma particularidade do MRI.

### 17.5 O resumo pratico

- A GVL nao torna `+=`, `<<` ou escrita em hash atomicos entre threads. Sequencias
  precisam de `Mutex`.
- A GVL e liberada em IO e sleep; e ai que outra thread se intromete.
- Adquirir/liberar GVL e Mutex sao barreiras de memoria; e como visibilidade
  cross-thread acontece aqui.
- O event loop troca tudo isso por "uma thread, uma coisa de cada vez". Os locks
  internos ficam por camada e por portabilidade, nao por necessidade no MRI atual.

## 18. Nota tecnica detalhada: rodada de performance, durabilidade e limites

Esta rodada parou de afirmar e comecou a medir, e fechou varios buracos entre o que
o journal alegava e o que estava demonstrado.

### 18.1 Benchmark: por que e, sobretudo, como

A motivacao primeiro. O journal tinha dezenas de frases como "o mutex unico vira
gargalo" e "um comando O(N) trava o loop". Nenhuma tinha um numero. Uma alegacao de
performance sem medida e uma hipotese, nao um resultado. O harness
(`benchmarks/bench.rb`, stdlib pura) existe para transformar hipotese em medida e,
quando for o caso, refuta-la.

Como medir, ponto por ponto, porque o "como" e onde a maioria dos benchmarks mente:

- **Closed loop.** Um numero fixo de conexoes, cada uma manda um comando, espera a
  resposta, manda o proximo. Isso mede tempo de servico sob uma concorrencia fixa,
  que e o que um servidor single-threaded oferece.
- **Warmup com barreira.** Os primeiros comandos de cada cliente sao descartados
  (setup de conexao, page faults, aquecimento). Os clientes aquecem, sao soltos
  juntos por uma barreira, e so a janela medida e cronometrada. Warmup nunca
  contamina o throughput.
- **Percentis, nao media.** A cauda (p99, p999) e o que o usuario sente. Uma media
  esconde um servidor rapido em 90% e congelado nos outros 10%.
- **RESP2 no fio.** Respostas com tamanho prefixado parseiam sem ambiguidade,
  incluindo o bulk multilinha do `INFO` que o protocolo textual nao enquadra.

A primeira licao veio do proprio benchmark mentindo. A versao ingenua mostrou um
p999 de ~48ms que sumiu quando o cliente passou a setar `TCP_NODELAY`. Com o algoritmo
de Nagle ligado no cliente, um request pequeno fica preso no kernel do cliente
esperando coalescer, e o delayed-ACK do servidor espera para pegar carona, gerando
travadas de ~40ms que nao tem nada a ver com o servidor. Um benchmark com Nagle no
cliente mede a pilha de sockets, nao o servidor. Higiene de medida primeiro.

A licao principal veio depois. A carga `GET+INFO 1%` (99% GET, 1% INFO) caiu para
~9,7k ops/s com p999 ~12ms, contra ~30k ops/s e p999 ~6ms da carga so de GET/SET.
Apenas 1% dos comandos era `INFO`, e mesmo assim todos os clientes desaceleraram.
Esse e o event loop single-threaded encontrando um comando O(N): o `INFO` varria
todo o keyspace na unica thread que serve todos. A alegacao "O(N) trava o loop"
deixou de ser hipotese. Depois do conserto (proxima subsecao), a mesma carga voltou
a ~36k ops/s e p999 ~2ms. O benchmark achou o problema e provou o conserto. Esse e o
ciclo inteiro: medir, mudar, medir de novo. Numeros e a evidencia em
`benchmarks/baseline.md`.

### 18.2 Complexidade como requisito: INFO de O(N) para O(1)

Num servidor single-threaded, a complexidade de cada comando e um requisito, nao um
detalhe. O `INFO` calculava `keys` e `keys_with_expiry` varrendo todas as entradas.
O conserto foi manter contadores incrementais no `Store`, atualizados em cada
insercao e remocao, atraves de dois unicos metodos (`store_entry`/`remove_entry`) por
onde todo caminho de mutacao passa, para os contadores nunca divergirem.

A troca honesta: um contador de chaves *vivas* nao e mantivel em O(1) com expiracao
preguicosa, porque uma chave expira pelo relogio, sem rodar codigo que decremente.
Entao os contadores sao *fisicos*, como o `DBSIZE` do Redis: contam entradas ainda
presentes, incluindo as que expiraram mas nao foram despejadas. A expiracao
preguicosa e a ativa convergem o numero fisico para o vivo. O teste documenta isso:
uma chave expirada e contada ate algo a despejar.

### 18.3 A escada da durabilidade, e o que um teste prova

`flush` move o buffer do Ruby para o kernel; `fsync` forca o dado ao disco; mas a
entrada de diretorio de um arquivo novo (ou de um `rename` de compaction) so e
duravel apos `fsync` no proprio diretorio. Cada degrau protege contra uma falha
diferente, e o codigo agora cobre os tres quando `fsync` esta ligado.

O teste de crash mostra a fronteira do que da para provar. Ele sobe o servidor, faz
um `SET`, recebe o `OK`, mata o processo com `SIGKILL` e sobe outro processo no mesmo
AOF, verificando que o valor voltou. Isso prova a ordenacao write-ahead: um write
confirmado ao cliente sobrevive a morte do processo. Mas nao prova `fsync`: o
`SIGKILL` mata o processo, e o page cache do SO mantem o dado escrito, entao um
registro com `flush` ja esta la para o proximo processo. `fsync` e o `fsync` de
diretorio protegem contra queda de energia / panico de kernel, que um teste em
espaco de usuario nao simula. Essa fronteira e a licao: recuperacao de crash de
processo e testavel; durabilidade contra queda de energia e raciocinada, nao testada.

### 18.4 Limite de recurso: o cliente que nao le

O event loop bufferiza respostas por conexao para lidar com escrita parcial. Sem
limite, um cliente que pipeline-a muitos comandos e nunca le suas respostas faria
esse buffer crescer sem fim: exaustao de memoria por cliente lento. A defesa e a
mesma do `client-output-buffer-limit` do Redis: limitar o backlog e derrubar a
conexao quando passa do cap. O teste e um cliente que manda 500 respostas grandes
sem ler nenhuma; a prova de que o servidor o derrubou e o proprio `EPIPE` que as
escritas do cliente passam a tomar. O sinal de sucesso e o cano quebrado.

### 18.5 Expiracao ativa: o vazamento que a preguica deixa

Expiracao preguicosa so despeja no acesso, entao uma chave com TTL nunca mais lida
vaza para sempre, e o contador fisico a conta. A expiracao ativa e um ciclo que
amostra um numero limitado de chaves-com-expiracao e despeja as expiradas. Limitado e
o ponto inteiro: uma varredura O(N) travaria o loop single-threaded em que ela roda,
exatamente o erro que o `INFO` cometia. Para amostrar sem O(N), o `Store` mantem um
dicionario de chaves voláteis separado. O loop a chama como o `serverCron` do Redis:
um tique de fundo throttled a ~10Hz pelo relogio monotonico, que roda independente de
carga e nunca fica em busy-spin. Simplificacoes assumidas e documentadas: a amostra e
por ordem de insercao (nao aleatoria como no Redis) e nao e adaptativa (nao repete
quando a taxa de acerto e alta).

### 18.6 Fuzzing: os casos que voce nao pensou

Os testes deterministicos do parser checam as entradas que imaginamos. O fuzz checa
20.000 que nao imaginamos, com PRNG seedado para reproduzir qualquer falha. Ele
afirma uma propriedade, nao um exemplo: `consume` e total, ou seja, para qualquer
sequencia de bytes ele devolve `[parts, rest]`, devolve `nil` (incompleto) ou levanta
`ProtocolError`, e nunca um erro inesperado nem um hang. Passou limpo, o que e um
sinal forte de que o parser trata lixo arbitrario com graca. Onde o teste
deterministico diz "esse caso funciona", o fuzz diz "nenhum caso quebra de um jeito
que eu nao previ" -- uma garantia diferente, e mais dificil de obter com exemplos.

## 19. Nota tecnica detalhada: o segundo tipo (listas)

Ate aqui todo valor era string. Adicionar listas (`LPUSH`, `RPUSH`, `LLEN`,
`LRANGE`) e a maior expansao conceitual do projeto, porque introduz a ideia de
*tipo* numa chave e tudo que decorre dela.

### 19.1 Dispatch por tipo e WRONGTYPE

O `Entry` agora guarda um valor que e String ou Array. Toda operacao precisa
checar: um comando de lista numa chave string, ou um `GET` numa chave lista, e um
erro de tipo. O dominio levanta `Domain::TypeMismatch`; a aplicacao o traduz em
`-WRONGTYPE Operation against a key holding the wrong kind of value`, a mesma
mensagem do Redis. A checagem mora no dominio (e ele que conhece a forma do valor),
e a traducao para resposta mora na aplicacao (e ela que conhece o protocolo de
erro). O `rescue` fica no `execute`, cobrindo qualquer comando que toque o store.

### 19.2 Aridade variadica sem inchar o contrato

`LPUSH key v1 v2 ...` tem aridade variavel, enquanto os comandos antigos tinham
aridade fixa. Em vez de adicionar um campo `variadic` a todos os specs, a `arity`
passou a ser um Integer (fixo) ou um Range (variadico), e a checagem virou
`arity === parts.length`. Isso funciona para os dois porque `Integer#===` e
igualdade e `Range#===` e pertinencia: `3 === 5` e falso, `(3..) === 5` e
verdadeiro. Nenhum spec antigo mudou; `LPUSH` usa `(3..)`.

### 19.3 Listas e a fronteira de durabilidade

Listas sao um tipo duravel, entao `LPUSH`/`RPUSH` entram no AOF e precisam ser
reconstruiveis. Duas pecas: o `apply_durable` ganhou os dois comandos, e a
compaction passou a emitir `RPUSH key v1 v2 ...` para um valor Array, em vez de
`SET`, para reconstruir a lista a partir do snapshot.

Um detalhe sutil de WAL apareceu aqui. Para `EXPIRE`, o decorator valida o argumento
antes de gravar, entao um comando invalido nunca entra no AOF. Para um `LPUSH` numa
chave string, o erro de tipo so e descoberto na hora de aplicar, depois do append.
A escolha foi deixar `apply_durable` resgatar `TypeMismatch` e devolver o WRONGTYPE:
ao vivo, o cliente ve o erro e o store nao muda; no replay, o mesmo registro levanta
`TypeMismatch`, e tambem resgatado, e vira no-op. O registro "ruim" no AOF e inofensivo
porque os dois lados o tratam igual, mantendo estado vivo e reconstruido identicos.
E o mesmo tipo de no-op que um `DEL` em chave ausente ja gerava: o AOF nao e um
registro so de efeitos, e isso e aceito e documentado.
