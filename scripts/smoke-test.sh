#!/usr/bin/env bash
#
# Testes de fumaca da CloudStore - valida TODAS as tarefas da atividade.
#
# Uso:   ./scripts/smoke-test.sh
# Roda localmente (Git Bash / WSL / Linux) e no GitHub Actions.
#
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ/loja-docker"

VERDE=$'\033[0;32m'; VERMELHO=$'\033[0;31m'; AZUL=$'\033[0;36m'; RESET=$'\033[0m'
FALHAS=0

# jq nao vem instalado no Windows. Se nao existir, usa a imagem oficial
# em container - assim o mesmo script roda no Git Bash e no CI.
if ! command -v jq >/dev/null 2>&1; then
  jq() { docker run --rm -i ghcr.io/jqlang/jq:latest "$@"; }
fi

titulo()  { printf '\n%s== %s ==%s\n' "$AZUL" "$1" "$RESET"; }
ok()      { printf '  %sPASSOU%s  %s\n' "$VERDE" "$RESET" "$1"; }
falhou()  { printf '  %sFALHOU%s  %s\n' "$VERMELHO" "$RESET" "$1"; FALHAS=$((FALHAS + 1)); }

# Espera os servicos com healthcheck ficarem "healthy".
esperar_saudaveis() {
  local limite=$((SECONDS + 120))
  while [ $SECONDS -lt $limite ]; do
    local pendentes=0
    for c in loja-web loja-banco loja-minio; do
      local estado
      estado="$(docker inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null || echo ausente)"
      [ "$estado" = "healthy" ] || pendentes=$((pendentes + 1))
    done
    [ "$pendentes" -eq 0 ] && return 0
    sleep 3
  done
  echo "Timeout esperando os servicos ficarem saudaveis:"
  docker compose ps
  return 1
}

# Repete um comando ate dar certo, dentro de um limite de tempo.
tentar_ate() {
  local segundos="$1"; shift
  local limite=$((SECONDS + segundos))
  while [ $SECONDS -lt $limite ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
titulo "TAREFA 2/3/4 - subindo a stack"
# ---------------------------------------------------------------------------
docker compose up -d --wait --wait-timeout 180 || docker compose up -d
esperar_saudaveis
docker compose ps

# ---------------------------------------------------------------------------
titulo "REGRA DE OURO - apenas web e minio podem publicar portas"
# ---------------------------------------------------------------------------
# Verificacao ESTATICA (o docker-compose.yml declarado)
publicados="$(docker compose config --format json \
  | jq -r '.services | to_entries[] | select(.value.ports != null) | .key' \
  | sort | paste -sd, -)"
if [ "$publicados" = "minio,web" ]; then
  ok "compose declara ports: apenas em -> $publicados"
else
  falhou "services com ports: '$publicados' (esperado 'minio,web')"
fi

# O minio so pode publicar o console (9001), nunca a API S3 (9000)
portas_minio="$(docker compose config --format json \
  | jq -r '.services.minio.ports[].published' | sort | paste -sd, -)"
if [ "$portas_minio" = "9001" ]; then
  ok "minio publica somente a porta do console -> $portas_minio"
else
  falhou "minio publica '$portas_minio' (esperado somente '9001')"
fi

# Verificacao em TEMPO DE EXECUCAO (o que o Docker realmente mapeou)
for c in loja-api loja-banco; do
  mapeadas="$(docker inspect "$c" \
    --format '{{range $p, $conf := .NetworkSettings.Ports}}{{if $conf}}{{$p}} {{end}}{{end}}')"
  if [ -z "$mapeadas" ]; then
    ok "$c nao possui nenhuma porta publicada no host"
  else
    falhou "$c publicou portas no host: $mapeadas"
  fi
done

# ---------------------------------------------------------------------------
titulo "TAREFA 2 - vitrine publica"
# ---------------------------------------------------------------------------
if curl -fsS http://localhost:8080/ | grep -q "CloudStore"; then
  ok "http://localhost:8080/ responde e contem 'CloudStore'"
else
  falhou "vitrine nao respondeu como esperado"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 3 - API interna via proxy reverso"
# ---------------------------------------------------------------------------
resposta_api="$(curl -fsS http://localhost:8080/api/ || true)"
if grep -q "Hostname:" <<<"$resposta_api"; then
  ok "/api/ devolve a resposta do whoami"
else
  falhou "/api/ nao devolveu a resposta do whoami"
fi

# RemoteAddr precisa ser o container web, provando que passou pelo proxy
if grep -q "X-Forwarded-For:" <<<"$resposta_api"; then
  ok "resposta traz X-Forwarded-For (passou pelo proxy reverso)"
else
  falhou "resposta sem X-Forwarded-For - o proxy nao esta encaminhando"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 4 - banco privado responde PONG"
# ---------------------------------------------------------------------------
if [ "$(docker compose exec -T banco redis-cli ping | tr -d '\r')" = "PONG" ]; then
  ok "redis-cli ping -> PONG (de dentro do container)"
else
  falhou "redis-cli ping nao devolveu PONG"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 5 - isolamento de falhas por camada"
# ---------------------------------------------------------------------------
docker compose stop api >/dev/null 2>&1

if curl -fsS -o /dev/null http://localhost:8080/; then
  ok "vitrine CONTINUA no ar com a API parada"
else
  falhou "vitrine caiu junto com a API - o isolamento falhou"
fi

codigo_api="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/api/ || true)"
if [ "$codigo_api" != "200" ]; then
  ok "/api/ falha com a API parada (HTTP $codigo_api)"
else
  falhou "/api/ respondeu 200 mesmo com a API parada"
fi

docker compose start api >/dev/null 2>&1
if ! tentar_ate 30 curl -fsS -o /dev/null http://localhost:8080/api/; then
  # Fallback: o nginx pode ter guardado o IP antigo da API.
  echo "  (aplicando fallback: docker compose restart web)"
  docker compose restart web >/dev/null 2>&1
  esperar_saudaveis
fi
if curl -fsS -o /dev/null http://localhost:8080/api/; then
  ok "/api/ volta a funcionar depois de restaurar a API"
else
  falhou "/api/ nao voltou depois do start"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 6 - persistencia do banco (armazenamento de bloco)"
# ---------------------------------------------------------------------------
docker compose exec -T banco redis-cli set produto:1 "Camiseta" >/dev/null
echo "  gravado produto:1 = Camiseta; derrubando tudo com 'docker compose down'..."
docker compose down >/dev/null 2>&1
docker compose up -d --wait --wait-timeout 180 >/dev/null 2>&1 || docker compose up -d >/dev/null 2>&1
esperar_saudaveis

valor="$(docker compose exec -T banco redis-cli get produto:1 | tr -d '\r' || true)"
if [ "$valor" = "Camiseta" ]; then
  ok "dado sobreviveu ao down/up -> produto:1 = '$valor'"
else
  falhou "dado perdido apos o down -> produto:1 = '$valor' (esperado 'Camiseta')"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 7 - armazenamento de objetos (MinIO)"
# ---------------------------------------------------------------------------
if curl -fsS -o /dev/null http://localhost:9001/; then
  ok "console do MinIO publicado em http://localhost:9001/"
else
  falhou "console do MinIO nao respondeu na 9001"
fi

# A API S3 (9000) NAO pode estar acessivel pelo host
if curl -fsS -o /dev/null --max-time 5 http://localhost:9000/minio/health/live 2>/dev/null; then
  falhou "API S3 do MinIO (9000) esta acessivel pelo host - deveria ser interna"
else
  ok "API S3 (9000) inacessivel pelo host, como as demais camadas privadas"
fi

# ...mas PRECISA responder de dentro da rede interna
if docker compose exec -T web wget -q --spider http://minio:9000/minio/health/live; then
  ok "API S3 responde de DENTRO da rede interna (http://minio:9000)"
else
  falhou "API S3 nao respondeu de dentro da rede interna"
fi

# ---------------------------------------------------------------------------
titulo "TAREFA 8 - versionamento de bucket disponivel"
# ---------------------------------------------------------------------------
docker compose exec -T minio mc alias set ci http://127.0.0.1:9000 admin admin12345 >/dev/null 2>&1
docker compose exec -T minio mc mb --ignore-existing ci/ci-versionamento >/dev/null 2>&1
docker compose exec -T minio mc version enable ci/ci-versionamento >/dev/null 2>&1
estado_versao="$(docker compose exec -T minio mc version info ci/ci-versionamento 2>/dev/null | tr -d '\r' || true)"
if grep -qi "enabled" <<<"$estado_versao"; then
  ok "versionamento pode ser habilitado no bucket"
else
  falhou "nao foi possivel habilitar versionamento: $estado_versao"
fi
docker compose exec -T minio mc rb --force ci/ci-versionamento >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
titulo "RESULTADO"
# ---------------------------------------------------------------------------
if [ "$FALHAS" -eq 0 ]; then
  printf '%sTodos os testes passaram.%s\n' "$VERDE" "$RESET"
  exit 0
else
  printf '%s%d teste(s) falharam.%s\n' "$VERMELHO" "$FALHAS" "$RESET"
  exit 1
fi
