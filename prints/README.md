# Evidências (prints da atividade)

Capturas de tela da stack em execução. Cada arquivo abaixo indica **o que aparece**,
**qual comando/tela** originou o print e **qual requisito** ele comprova.

Todos foram capturados com a stack real rodando via `docker compose up -d`.
Os prints de terminal são janelas reais do PowerShell, com os comandos digitados na janela.

---

## Prints exigidos pela atividade

### `01-vitrine-localhost-8080.png`
- **O que aparece:** a vitrine da CloudStore renderizada, com a barra de endereço em `localhost:8080`.
- **Tela:** navegador em <http://localhost:8080>
- **Comprova:** **Tarefa 2** — o frontend é servido pelo Nginx e é a camada pública, com a porta `8080` publicada.

### `02-api-localhost-8080-api.png`
- **O que aparece:** a resposta em texto do `traefik/whoami`, com `Hostname`, os `IP` internos e o `RemoteAddr`. URL em `localhost:8080/api/`.
- **Tela:** navegador em <http://localhost:8080/api/>
- **Comprova:** **Tarefa 3** — o proxy reverso publica a API interna sem que ela tenha porta própria.
- **Detalhe que vale apontar:** o `RemoteAddr` é `172.18.0.x`, o IP do contêiner `web` dentro da rede
  `interna` — e não o IP do host. É a prova de que a requisição passou pelo proxy em vez de ir direto
  à API. Os cabeçalhos `X-Forwarded-For` e `X-Real-Ip` confirmam o mesmo.

### `03-docker-compose-ps.png`
- **O que aparece:** a saída completa de `docker compose ps`, com a coluna `PORTS` legível.
- **Comando:** `docker compose ps`
- **Comprova:** **Tarefas 3, 4 e 7** — quem publica porta e quem não publica.
- **Como ler a coluna PORTS:**

  | Contêiner | PORTS | Leitura |
  |---|---|---|
  | `loja-web` | `0.0.0.0:8080->80/tcp` | **porta publicada** — existe mapeamento no host |
  | `loja-minio` | `0.0.0.0:9001->9001/tcp` | **porta publicada** — só o console, conforme a Tarefa 7 |
  | `loja-api` | `80/tcp` | apenas `EXPOSE` interno — **sem** porta no host |
  | `loja-banco` | `6379/tcp` | apenas `EXPOSE` interno — **sem** porta no host |

  O que caracteriza porta publicada é a seta com o IP do host (`0.0.0.0:...->...`).
  Valores como `80/tcp` sozinhos são só a declaração de qual porta o serviço escuta **dentro** da rede.

### `04-redis-cli-ping-pong.png`
- **O que aparece:** dois comandos e suas respostas. O segundo imprime o `hostname` do contêiner
  antes do `PONG`, confirmando onde o comando rodou.
- **Comandos:**
  ```powershell
  docker compose exec banco redis-cli ping
  docker compose exec banco sh -c "hostname; redis-cli ping"
  ```
- **Comprova:** **Tarefa 4** — o banco funciona **de dentro** da rede, mesmo sem porta publicada.

### `05-teste-de-falha-completo.png`
- **O que aparece, na mesma tela:**
  - à esquerda, a vitrine funcionando em `localhost:8080`;
  - à direita, `localhost:8080/api/` com **`504 Gateway Time-out`** do nginx;
  - embaixo, o terminal com `docker compose stop api` → `Container loja-api Stopped`, e o
    `docker compose ps` seguinte **sem a linha `loja-api`**.
- **Comprova:** **Tarefa 5** — a falha ficou **contida** na camada da API.
- **Sobre o código do erro:** o PDF menciona **502**, mas aqui aparece **504**. Os dois são erro de
  gateway e provam a mesma coisa. Quando o contêiner é *parado*, o IP dele some da rede e o nginx
  fica esperando resposta até estourar o timeout (**504**); o **502** apareceria se a conexão fosse
  recusada ativamente. O `nginx.conf` define `proxy_connect_timeout 3s` justamente para o erro
  aparecer em ~3 segundos em vez dos 60 s padrão.

Versões separadas do mesmo teste, caso seja preferível montar o print no documento:

| Arquivo | Conteúdo |
|---|---|
| `05a-vitrine-no-ar-com-api-parada.png` | só a vitrine, funcionando com a API parada |
| `05b-api-com-erro-504.png` | só o `/api/` com o erro de gateway |
| `05c-terminal-api-parada.png` | só o terminal com o `stop` e o `ps` |

---

## Prints complementares (Tarefas 6, 7, 8 e CI/CD)

### `06-persistencia-volume-tarefa6.png`
- **O que aparece:** a sequência completa da persistência, do início ao fim.
- **Comandos:**
  ```powershell
  docker compose exec banco redis-cli set produto:1 "Camiseta"
  docker compose exec banco redis-cli get produto:1
  docker compose down
  docker volume ls --filter name=loja-docker
  docker compose up -d
  docker compose exec banco redis-cli get produto:1
  ```
- **Comprova:** **Tarefa 6** — armazenamento de bloco e durabilidade.
- **O ponto central:** o `down` removeu os **quatro contêineres e a rede**, mas
  `loja-docker_dados-banco` e `loja-docker_dados-objetos` continuaram existindo — e depois do `up`
  o `produto:1` ainda valia `"Camiseta"`. É o "disco" sobrevivendo à "VM": ciclo de vida do volume
  independente do ciclo de vida do contêiner.

### `07-minio-bucket-produtos.png`
- **O que aparece:** o console do MinIO em `localhost:9001`, com o bucket `produtos`
  (`Access: PRIVATE`) e o objeto `camiseta.png`.
- **Comprova:** **Tarefa 7** — armazenamento de objetos.
- **Complemento importante:** o console está publicado na `9001`, mas a **API S3 (porta 9000)
  continua interna**. Verificação:
  ```powershell
  curl.exe --max-time 5 http://localhost:9000/minio/health/live   # falha: sem porta no host
  docker compose exec web wget -q --spider http://minio:9000/minio/health/live   # OK: por dentro
  ```

### `08-minio-versionamento-duas-versoes.png`
- **O que aparece:** a tela `camiseta.png Versions`, com **2 Versions** e as duas versões listadas,
  cada uma com seu *Version ID* e tamanho distintos — `v2` marcada como `CURRENT VERSION` e `v1`
  ainda disponível para restaurar.
- **Comprova:** **Tarefa 8** — versionamento protegendo contra sobrescrita acidental.
- **Como foi produzido:** com o versionamento habilitado no bucket, duas imagens **diferentes**
  foram enviadas com o **mesmo nome** (`camiseta.png`). Sem versionamento, a segunda teria destruído
  a primeira; com versionamento, as duas coexistem.

### `09-github-actions-pipeline.png`
- **O que aparece:** a aba **Actions** do repositório com a execução concluída em verde.
- **Tela:** <https://github.com/lucasetculbra/cloudstore-docker/actions>
- **Comprova:** **CI/CD** — o pipeline roda automaticamente a cada push.

### `10-github-actions-jobs.png`
- **O que aparece:** o detalhe da execução, com o encadeamento das etapas
  `Validar configuracao` → `Testes de integracao` → `Publicar imagem da vitrine`,
  todas em verde, e o artefato publicado.
- **Comprova:** **CI/CD** — as etapas de validação, teste de integração e entrega.
- **O que o pipeline realmente verifica:** além de subir a stack e rodar as 15 asserções que cobrem
  as Tarefas 2 a 8, a etapa `validar` trata a regra de segurança da arquitetura como *policy as code*:
  o build **falha** se a `api` ou o `banco` ganharem `ports:`, ou se o MinIO publicar qualquer porta
  além da `9001`.

---

## Como estes prints foram capturados

As capturas foram feitas na máquina do próprio projeto, com a stack real em execução:

- **Prints de navegador:** janelas reais do Chrome, abertas num perfil temporário e limpo (sem
  extensões, sem sessão pessoal), posicionadas e capturadas via API do Windows. A barra de endereço
  aparece em todos, como a atividade exige.
- **Prints de terminal:** janelas reais do PowerShell. Os comandos foram **digitados na janela**
  (via envio de teclas), não simulados — a saída é a saída verdadeira do Docker.
- **Prints do MinIO:** login real no console (`admin`), navegação real pelo bucket.

Nenhuma imagem foi montada, editada ou teve saída reproduzida artificialmente.
