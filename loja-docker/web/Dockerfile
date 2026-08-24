# Empacota a vitrine (HTML + configuracao do proxy reverso) numa imagem
# imutavel, publicada pelo pipeline de CD no GitHub Container Registry.
#
# No dia a dia o docker-compose.yml usa bind mounts, porque editar um
# arquivo e dar F5 e mais rapido que reconstruir a imagem. Para entregar
# em producao vale o contrario: a imagem carrega o conteudo e a versao
# fica registrada na tag.
FROM nginx:alpine

LABEL org.opencontainers.image.title="CloudStore - vitrine" \
      org.opencontainers.image.description="Frontend Nginx da CloudStore com proxy reverso para a API interna" \
      org.opencontainers.image.source="https://github.com/lucasetculbra/cloudstore-docker"

COPY html/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

# 127.0.0.1 e nao localhost: dentro do container "localhost" resolve
# primeiro para ::1 (IPv6) e o nginx escuta apenas em IPv4.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider http://127.0.0.1/ || exit 1
