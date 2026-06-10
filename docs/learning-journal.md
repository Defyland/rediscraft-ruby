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

## 8. Quais testes protegem quais decisoes

`test/unit/command_executor_test.rb` protege comando, aridade, TTL, que `DEL`
em chave expirada reporta 0 e que `INFO` reporta gauges de keyspace.

`test/unit/command_registry_test.rb` protege o contrato compartilhado entre
executor e AOF: nomes publicos, aridade, durabilidade e transformacao de
`EXPIRE` para `EXPIREAT`, alem do parsing de inteiro nao negativo.

`test/unit/text_protocol_test.rb` protege parsing e tipo de resposta.

`test/unit/resp2_protocol_test.rb` protege parser e formatter RESP2, incluindo a
diferenca entre EOF normal, null bulk invalido em comando e erro de protocolo.

`test/integration/tcp_server_test.rb` protege conexao TCP real e clientes
concorrentes, incluindo comando RESP2 real e erro RESP malformado visivel ao
cliente. Tambem protege shutdown de clientes ociosos.

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
| `8e5115f` | Append e mutacao do AOF eram secoes criticas separadas | `AofCommandExecutor` serializa append e mutacao no mesmo mutex de escrita | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `002520f` | Formatter textual carregava heuristica morta | Remocao do fallback inalcancavel; formatter so trata `Response` ou `nil` | `bin/test`, `bin/check` |
| `b7789b4` | `delete` escondia expiracao preguicosa load-bearing | Intencao explicita no delete e teste de `DEL` em chave expirada | `ruby -Itest test/unit/command_executor_test.rb`, `bin/test`, `bin/check` |
| `815ff40` | Help do `--aof` dizia "future support" para recurso ativo | Texto de CLI alinhado ao comportamento real | `ruby -c bin/rediscraft`, `bin/test`, `bin/check` |
| `4486faa` | Toolchain pinada em Ruby 3.4.2 | Bump para 3.4.9 em `.ruby-version` e `.tool-versions` | `bin/check` |
| `4b8c75d` | EXPIRE vivo divergia do replay (relogio duplo e truncagem) | Execucao viva aplica o registro persistido em precisao cheia | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `5f94b73` | `apply_durable` e `apply_record` duplicavam o mapeamento | Replay aplica pelo mesmo `apply_durable` via aplicador injetado | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `d5a748d` | AOF so dava flush, sem garantia em disco | `fsync` opcional por append e flag `--fsync` | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |
| `30a9a92` | Faltava qualquer observabilidade | Comando `INFO` com gauges de keyspace | `ruby -Itest test/unit/command_executor_test.rb`, `bin/test`, `bin/check` |
| `19ecdf2` | AOF crescia sem limite | Compaction reescreve o log do estado vivo via `rename` atomico | `ruby -Itest test/unit/aof_command_executor_test.rb`, `bin/test`, `bin/check` |

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
limite de conexoes, metricas completas (Prometheus/tracing) e auto-compaction por
razao de crescimento. Ja existem, em forma de estudo: `fsync` opcional, compaction
manual e `INFO` por gauges.

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
