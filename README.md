# orbittracking-servidor

Configuração do servidor de [orbittracking.duckdns.org](http://orbittracking.duckdns.org): página inicial e nginx na frente de dois apps, cada um no seu subdomínio, com HTTPS.

| Endereço | Conteúdo | Serviço (systemd) |
|---|---|---|
| `orbittracking.duckdns.org` (e `www.`) | Página inicial ([site/index.html](site/index.html)) | nginx |
| `orbit.orbittracking.duckdns.org` | [orbit-tools](https://github.com/francisvalguedes/orbit-tools) | `orbit-tools`, em `127.0.0.1:8010` |
| `propag.orbittracking.duckdns.org` | [TrajectoryOrbitPropag](https://github.com/francisvalguedes/TrajectoryOrbitPropag) (versão anterior) | `trajectory-orbit-propag`, em `127.0.0.1:8080` |

Os apps escutam só na própria máquina; o nginx é o único acesso de fora, pelas portas 80 e 443. O DuckDNS resolve qualquer subdomínio de `orbittracking.duckdns.org` para o IP da VM: não é preciso cadastrar os subdomínios.

Testado para uma VM Ubuntu da Oracle Cloud (OCI) com 1 GB de memória.

## 1. VM

### Memória (swap)

Com 1 GB, os dois apps e o nginx cabem, mas buscas grandes no orbit-tools e o Streamlit passam do limite sem swap:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### Firewall

São dois, e os dois precisam liberar as portas **80** e **443**:

1. **Console da OCI:** na VCN da VM, em *Security List* (ou *Network Security Group*), regras de entrada TCP 80 e TCP 443 de `0.0.0.0/0`.
2. **Dentro da VM** (as imagens Ubuntu da OCI bloqueiam tudo menos o SSH):

   ```bash
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT
   sudo iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT
   sudo netfilter-persistent save
   ```

As portas dos apps (8010, 8080) **não** devem ser abertas.

Se a VM tinha o redirecionamento 80 → 8080 do README do TrajectoryOrbitPropag, remova (senão ele toma a porta 80 do nginx):

```bash
sudo iptables -t nat -L PREROUTING -n --line-numbers         # procure REDIRECT ... redir ports 8080
sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
sudo netfilter-persistent save
```

## 2. Apps

### orbit-tools

Pelo [guia do systemd do orbit-tools](https://github.com/francisvalguedes/orbit-tools/blob/main/docs/implantacao_systemd.md), com o frontend compilado pelo GitHub (jeito **A**: não compile o frontend numa VM de 1 GB). O guia já deixa o serviço em `127.0.0.1:8010`; pule a seção do nginx dele, que é substituída por este repositório.

### TrajectoryOrbitPropag

Pelo README do app, com o serviço systemd do `install.sh` (a pasta e o usuário podem ser outros):

```bash
git clone https://github.com/francisvalguedes/TrajectoryOrbitPropag.git ~/TrajectoryOrbitPropag
cd ~/TrajectoryOrbitPropag
./install.sh --service
```

O serviço escuta em todas as interfaces; restrinja à própria máquina, atrás do nginx:

```bash
sudo systemctl edit trajectory-orbit-propag
```

No editor, entre as linhas de comentário indicadas:

```ini
[Service]
Environment=STREAMLIT_SERVER_ADDRESS=127.0.0.1
```

```bash
sudo systemctl restart trajectory-orbit-propag
curl -sI http://127.0.0.1:8080 | head -1           # HTTP/1.1 200 OK
```

## 3. nginx e página inicial

```bash
sudo apt update && sudo apt install -y nginx git
sudo git clone https://github.com/francisvalguedes/orbittracking-servidor.git /opt/orbittracking-servidor
sudo /opt/orbittracking-servidor/scripts/instalar.sh nginx orbittracking.duckdns.org
```

O script copia a página para `/var/www/orbittracking`, instala os três sites em `/etc/nginx/sites-available/orbittracking-*.conf` com o domínio, desativa o site padrão do nginx, testa (`nginx -t`) e recarrega. Confira em `http://orbittracking.duckdns.org`.

## 4. HTTPS

Certificados gratuitos do Let's Encrypt, renovados automaticamente:

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx --redirect \
  -d orbittracking.duckdns.org -d www.orbittracking.duckdns.org \
  -d orbit.orbittracking.duckdns.org -d propag.orbittracking.duckdns.org
sudo certbot renew --dry-run                        # confere a renovação automática
```

O certbot acrescenta o HTTPS e o redirecionamento de HTTP para HTTPS nos arquivos de `/etc/nginx/sites-available/`. Por isso o `instalar.sh` não sobrescreve esses arquivos sem `--sobrescrever`; se usar a opção, rode o certbot de novo.

Com HTTPS, a senha do Space-Track que os usuários digitam no orbit-tools viaja cifrada, e o botão "Copiar código" do navegador funciona.

## Atualização

| O quê | Como |
|---|---|
| Página inicial | `cd /opt/orbittracking-servidor && sudo git pull && sudo scripts/instalar.sh site` |
| Sites do nginx (mudaram no repositório) | `sudo scripts/instalar.sh nginx orbittracking.duckdns.org --sobrescrever` e o `certbot` da seção 4 |
| orbit-tools | Seção "Atualização" do guia do systemd do orbit-tools |
| TrajectoryOrbitPropag | `git pull && uv sync`, e `sudo systemctl restart trajectory-orbit-propag` |

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| Nada abre de fora | Portas 80/443 fechadas na Security List da OCI ou no `iptables` da VM |
| Página "Welcome to nginx" | Site padrão ainda ativo: rode o `instalar.sh nginx` |
| `502 Bad Gateway` num subdomínio | App parado: `systemctl status orbit-tools` ou `trajectory-orbit-propag` |
| TrajectoryOrbitPropag fica em "Please wait..." ou "Connecting" | nginx sem os cabeçalhos de WebSocket (`Upgrade`, `Connection`) |
| Porta 80 abre o Streamlit em vez da página | Redirecionamento 80 → 8080 antigo no `iptables` (seção 1) |
| `certbot` falha no desafio | Porta 80 fechada, ou o DuckDNS com outro IP (confira em duckdns.org) |
| Progresso do orbit-tools parado, resultado de uma vez | `proxy_buffering off` ausente no site do orbit-tools |
| App reinicia sozinho, `Out of memory` no `journalctl -k` | Sem swap (seção 1) |
