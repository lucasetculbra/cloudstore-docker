# CloudStore — aplicação de três camadas com Docker

[![CI/CD](https://github.com/lucasetculbra/cloudstore-docker/actions/workflows/ci.yml/badge.svg)](https://github.com/lucasetculbra/cloudstore-docker/actions/workflows/ci.yml)

**Página do projeto:** <https://lucasetculbra.github.io/cloudstore-docker/>

Atividade avaliativa de **Computação em Nuvem** — implantação local, com Docker, de uma loja
online separada em camadas, reproduzindo o par **sub-rede pública / sub-rede privada** da nuvem.

A regra que organiza tudo: **só o que precisa receber tráfego de fora tem porta publicada.**
Todo o resto vive numa rede Docker interna, alcançável apenas por outros contêineres.

As evidências de execução estão em [`prints/`](prints/), com um
[índice explicando cada captura](prints/README.md) e o requisito que ela comprova.

---

## Arquitetura

```
       HOST (seu computador)
              │
              ├── :8080 ──────────────► tráfego público da loja
              └── :9001 ──────────────► console de administração do MinIO
              │
┌─────────────┼───────────────────────────────────────────────────────┐
│  rede Docker "interna"  (= VPC / sub-rede)                          │
│             ▼                                                       │
│   ┌───────────────────┐                                             │
│   │  web              │  /      → serve a vitrine (index.html)      │
│   │  nginx:alpine     │  /api/  → proxy_pass http://api:80/         │
│   └─────────┬─────────┘                                             │
│             │ (somente por dentro da rede)                          │
│   ┌─────────▼─────────┐  ┌──────────────────┐  ┌──────────────────┐ │
│   │  api              │  │  banco           │  │  minio           │ │
│   │  traefik/whoami   │  │  redis:alpine    │  │  API S3 :9000    │ │
│   │  :80  SEM ports:  │  │  :6379 SEM ports:│  │  SEM ports:      │ │
│   └───────────────────┘  └────────┬─────────┘  └────────┬─────────┘ │
│                                   │                     │           │
└───────────────────────────────────┼─────────────────────┼───────────┘
                                    ▼                     ▼
                          volume dados-banco      volume dados-objetos
                          (bloco / persistente)   (objetos / persistente)
```

| Conceito na nuvem | Equivalente aqui |
|---|---|
| VPC / sub-rede | rede Docker `interna` |
| VM / instância | contêiner |
| Sub-rede pública | serviço com `ports:` |
| Sub-rede privada | serviço sem `ports:` |
| Regra de grupo de segurança | a linha `ports:` do compose |
| Armazenamento de bloco (EBS) | volume `dados-banco` montado em `/data` |
| Armazenamento de objetos (S3) | MinIO + volume `dados-objetos` |

---

## Estrutura

```
.
├── .github/workflows/ci.yml     pipeline de CI/CD
├── scripts/smoke-test.sh        testes que validam as Tarefas 2 a 8
├── site/index.html              landing page publicada no GitHub Pages
├── prints/                      evidências de execução (+ índice em README.md)
└── loja-docker/
    ├── docker-compose.yml       as 4 camadas + rede + volumes
    └── web/
        ├── Dockerfile           empacota a vitrine (usado pelo CD)
        ├── nginx.conf           vitrine + proxy reverso /api/
        └── html/index.html      a vitrine da loja
```

---

## Como rodar

Requisitos: Docker Desktop (ou Docker Engine) com Compose v2.

```bash
cd loja-docker
docker compose up -d
docker compose ps
```

| Endereço | O que é |
|---|---|
| <http://localhost:8080> | vitrine da loja |
| <http://localhost:8080/api/> | API interna, servida através do proxy reverso |
| <http://localhost:9001> | console do MinIO (`admin` / `admin12345`) |

Para encerrar:

```bash
docker compose down       # mantém os volumes (dados sobrevivem)
docker compose down -v    # apaga também os volumes
```

---

## Verificando cada camada

```bash
# Vitrine e API pública
curl http://localhost:8080/
curl http://localhost:8080/api/

# O banco responde de DENTRO da rede
docker compose exec banco redis-cli ping           # -> PONG

# A API e o banco NÃO têm porta no host
docker compose port api 80                         # -> invalid IP:0
docker compose port banco 6379                     # -> invalid IP:0

# ...mas são alcançáveis por dentro
docker compose exec web wget -qO- http://api/
docker compose exec web wget -q --spider http://minio:9000/minio/health/live

# Persistência (armazenamento de bloco)
docker compose exec banco redis-cli set produto:1 "Camiseta"
docker compose down && docker compose up -d
docker compose exec banco redis-cli get produto:1  # -> "Camiseta"

# Isolamento de falhas por camada
docker compose stop api
curl http://localhost:8080/        # continua 200
curl -i http://localhost:8080/api/ # erro de gateway
docker compose start api
```

Ou rode tudo de uma vez:

```bash
./scripts/smoke-test.sh
```

---

## CI/CD

O pipeline em [`.github/workflows/ci.yml`](.github/workflows/ci.yml) roda a cada push e pull
request na `main`, em três etapas encadeadas:

### 1. `validar` — validação estática (segundos, não sobe nada)

- `docker compose config -q` — o YAML é válido?
- **Política de segurança como código:** falha o build se `api` ou `banco` ganharem `ports:`,
  e se o MinIO publicar qualquer porta além da `9001`. É a regra central da arquitetura
  virando um teste automático, em vez de depender de alguém lembrar dela na revisão.
- Confere se os volumes `dados-banco` e `dados-objetos` continuam declarados — sem eles a
  persistência quebraria silenciosamente.
- `shellcheck` no script de teste.

### 2. `testar` — integração de verdade

Sobe a stack completa no runner e executa [`scripts/smoke-test.sh`](scripts/smoke-test.sh),
que valida **todas as tarefas da atividade**: vitrine no ar, `/api/` servida pelo proxy,
`PONG` do Redis, ausência de portas publicadas na api e no banco, persistência do volume
através de um ciclo `down`/`up`, MinIO com console público e API S3 interna, e o teste de
isolamento de falhas (derruba a API, confirma que a vitrine sobrevive, restaura).

Em caso de falha, despeja os logs dos contêineres. No final, sempre `docker compose down -v`.

### 3. `publicar` — entrega contínua (só em push na `main`)

Constrói a imagem da vitrine a partir de [`loja-docker/web/Dockerfile`](loja-docker/web/Dockerfile)
e publica no **GitHub Container Registry**:

```
ghcr.io/lucasetculbra/cloudstore-docker/web:latest
ghcr.io/lucasetculbra/cloudstore-docker/web:sha-<commit>
```

A tag com o SHA do commit é o que torna um deploy rastreável e reversível: cada versão da
vitrine tem um identificador imutável, e voltar atrás é apontar para a tag anterior.

> **Por que bind mount no compose e `COPY` no Dockerfile?** No desenvolvimento, editar o
> `index.html` e dar F5 é mais rápido que reconstruir a imagem — por isso o compose usa
> bind mounts. Para produção vale o contrário: a imagem carrega o conteúdo, e a versão fica
> registrada na tag. São os dois lados do mesmo artefato.

### 4. `paginas` — GitHub Pages (só em push na `main`)

Monta e publica <https://lucasetculbra.github.io/cloudstore-docker/> a partir de
[`site/index.html`](site/index.html), da galeria de [`prints/`](prints/) e de um espelho
estático da vitrine em `/vitrine/`.

> ⚠️ **A rota `/api/` não funciona no GitHub Pages.** O Pages serve apenas arquivos estáticos —
> não há Nginx, contêiner de API nem rede interna por trás dele. O proxy reverso e a camada
> privada só existem quando a stack está rodando com `docker compose up -d`. É exatamente a
> diferença entre *servir um arquivo* e *operar uma aplicação de várias camadas*, e está dita
> na própria página.

---

## Problemas comuns

| Sintoma | Causa provável / solução |
|---|---|
| Erro 502 ou 504 em `/api/` | A API está parada ou o `proxy_pass` está errado. Confira o serviço `api` e a rota. |
| `host not found in upstream: api` | O `web` subiu sem a `api` na rede. Confira o serviço `api` e a rede `interna`. |
| `port already allocated` | A 8080 já está em uso. Troque para `"8081:80"` e acesse `localhost:8081`. |
| Aparece o nginx padrão | O volume do `index.html` não foi montado. Confira o caminho `./web/html`. |
| `/api/` segue com erro após `start api` | O nginx guardou o IP antigo. Rode `docker compose restart web`. |
| Console do MinIO não abre | Confira se a porta `9001` está publicada e se o contêiner está `healthy`. |
