#!/usr/bin/env bash
# Instala a página inicial e os sites do nginx (ver README.md).
#
#   sudo scripts/instalar.sh site                    só a página inicial (pode repetir a qualquer hora)
#   sudo scripts/instalar.sh nginx <domínio>         página e sites do nginx (primeira vez, antes do certbot)
#   sudo scripts/instalar.sh nginx <domínio> --sobrescrever
#                                                    refaz os sites; desfaz o HTTPS: rode o certbot de novo
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WWW=/var/www/orbittracking

[ "$(id -u)" = 0 ] || { echo "rode com sudo" >&2; exit 1; }

site() {
  install -d "$WWW"
  install -m 644 "$ROOT/site/index.html" "$WWW/index.html"
  echo "página inicial em $WWW"
}

nginx_sites() {
  local dominio=${1:?uso: $0 nginx <domínio> [--sobrescrever]} sobrescrever=${2:-}
  command -v nginx >/dev/null || { echo "nginx não instalado: sudo apt install nginx" >&2; exit 1; }
  for f in "$ROOT"/nginx/*.conf; do
    local nome dest
    nome=orbittracking-$(basename "$f")
    dest=/etc/nginx/sites-available/$nome
    # O certbot acrescenta o HTTPS nestes arquivos: não sobrescrever sem pedido
    if [ -e "$dest" ] && [ "$sobrescrever" != --sobrescrever ]; then
      echo "mantido $dest (já existe; para refazer: --sobrescrever)"
      continue
    fi
    sed "s/__DOMINIO__/$dominio/g" "$f" > "$dest"
    ln -sf "$dest" "/etc/nginx/sites-enabled/$nome"
    echo "instalado $dest"
  done
  # O site padrão do nginx responderia no lugar da página inicial a quem acessa pelo IP
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
}

case "${1:-}" in
  site) site ;;
  nginx) site; nginx_sites "${2:-}" "${3:-}" ;;
  *) sed -n '2,8p' "$0" >&2; exit 1 ;;
esac
