# orbittracking-servidor

Configuração do servidor de [orbittracking.duckdns.org](https://orbittracking.duckdns.org): página inicial e nginx na frente de dois apps, cada um no seu subdomínio, com HTTPS.

| Endereço | Conteúdo | Serviço systemd | Usuário | Código |
|---|---|---|---|---|
| `orbittracking.duckdns.org` (e `www.`) | Página inicial ([site/index.html](site/index.html)) | `nginx` | — | `/var/www/orbittracking` |
| `orbit.orbittracking.duckdns.org` | [orbit-tools](https://github.com/francisvalguedes/orbit-tools) | `orbit-tools`, em `127.0.0.1:8010` | `mirante` | `/opt/orbit-tools` |
| `propag.orbittracking.duckdns.org` | [TrajectoryOrbitPropag](https://github.com/francisvalguedes/TrajectoryOrbitPropag) (versão anterior) | `trajectory-orbit-propag`, em `127.0.0.1:8080` | `streamlit` | `/opt/TrajectoryOrbitPropag` |

Este repositório fica em `/opt/orbittracking-servidor`, do root.

- Os apps escutam só na própria máquina; o nginx é o único acesso de fora, pelas portas 80 e 443.
- Cada app roda com um usuário de serviço próprio, sem login nem `sudo`: uma falha num app não alcança o outro nem o resto da VM.
- O DuckDNS resolve qualquer subdomínio de `orbittracking.duckdns.org` para o IP da VM: não é preciso cadastrar os subdomínios.

Testado numa VM Ubuntu da Oracle Cloud (OCI) com 1 GB de memória. Ordem da instalação: VM, apps, nginx, HTTPS, monitoramento.

## 1. VM

### Memória (swap)

Com 1 GB, os dois apps e o nginx cabem, mas buscas grandes no orbit-tools e o Streamlit passam do limite sem swap:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### uv

Os dois apps usam o [uv](https://docs.astral.sh/uv/). Instalado em `/usr/local/bin`, ele fica disponível para os usuários de serviço:

```bash
sudo apt update && sudo apt install -y git curl
curl -LsSf https://astral.sh/uv/install.sh | sudo env UV_INSTALL_DIR=/usr/local/bin sh
```

### Firewall

São dois, e os dois precisam liberar as portas **80** e **443**.

**1. Console da OCI:** Compute → Instances → instância → Networking → Subnet → Security → Security List → **Add Ingress Rules**: Source CIDR `0.0.0.0/0`, TCP, Destination Port `80`; outra regra igual com `443`. Não use o intervalo `80-443`, que abriria todas as portas entre elas.

**2. Dentro da VM:** as imagens Ubuntu da OCI terminam a cadeia `INPUT` com um `REJECT` que bloqueia tudo menos o SSH. As regras novas entram **antes** dele:

```bash
sudo iptables -L INPUT -n --line-numbers          # anote o número da linha do REJECT
sudo iptables -I INPUT <linha do REJECT> -m state --state NEW -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT <linha do REJECT> -m state --state NEW -p tcp --dport 80 -j ACCEPT
sudo iptables -L INPUT -n --line-numbers          # 80 e 443 acima do REJECT; a 22 continua lá
sudo netfilter-persistent save
```

As cadeias `ufw-*` que aparecem depois do `REJECT` nunca são alcançadas; não ative o `ufw`, que brigaria com o `netfilter-persistent`. As portas dos apps (8010, 8080) **não** devem ser abertas.

**Se a VM usava o redirecionamento 80 → 8080** do README antigo do TrajectoryOrbitPropag, remova o redirecionamento e a liberação da 8080 (senão o Streamlit toma a porta 80 do nginx):

```bash
sudo iptables -t nat -L PREROUTING -n --line-numbers   # REDIRECT ... redir ports 8080
sudo iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
sudo iptables -D INPUT -p tcp --dport 8080 -j ACCEPT
sudo netfilter-persistent save
```

### IP e DNS

O IP público da VM (efêmero, na OCI) só muda se a instância for terminada ou o IP desassociado; com um IP reservado, nunca muda. O domínio é atualizado no [DuckDNS](https://www.duckdns.org): pelo site ou pelo script [duckdns](https://github.com/francisvalguedes/duckdns), que pode ficar desligado enquanto o IP não mudar. Se mudar, os três endereços saem do ar juntos (o monitoramento avisa): atualize o IP no DuckDNS; nginx, certificado e apps não precisam de ajuste.

## 2. Apps

### orbit-tools

Pelo [guia do systemd do orbit-tools](https://github.com/francisvalguedes/orbit-tools/blob/main/docs/implantacao_systemd.md): usuário `mirante`, código em `/opt/orbit-tools` e frontend compilado pelo GitHub (jeito **A**: não compile o frontend numa VM de 1 GB). O guia já deixa o serviço em `127.0.0.1:8010`; pule a seção do nginx dele, que é substituída por este repositório.

```bash
curl -s http://127.0.0.1:8010/api/meta | head -c 80; echo    # {"name":"orbit-tools",...
```

### TrajectoryOrbitPropag

O `install.sh --service` do app instala o serviço com o usuário que roda o script (que costuma ter `sudo`). Aqui o serviço é escrito à mão, com o usuário de serviço `streamlit` e já restrito a `127.0.0.1`:

```bash
sudo useradd --system --create-home --home-dir /var/lib/streamlit --shell /usr/sbin/nologin streamlit
sudo mkdir -p /opt/TrajectoryOrbitPropag && sudo chown streamlit: /opt/TrajectoryOrbitPropag
sudo -u streamlit git clone https://github.com/francisvalguedes/TrajectoryOrbitPropag.git /opt/TrajectoryOrbitPropag
sudo -H -u streamlit bash -c 'cd /opt/TrajectoryOrbitPropag && /usr/local/bin/uv sync --frozen'
```

Crie o serviço com `sudo nano /etc/systemd/system/trajectory-orbit-propag.service` (a linha `ExecStart` inteira numa linha só):

```ini
[Unit]
Description=TrajectoryOrbitPropag Streamlit app
Wants=network-online.target
After=network-online.target

[Service]
User=streamlit
Group=streamlit
WorkingDirectory=/opt/TrajectoryOrbitPropag
ExecStart=/opt/TrajectoryOrbitPropag/.venv/bin/streamlit run source/main.py --server.port 8080 --server.address 127.0.0.1 --server.headless true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo chown root:root /etc/systemd/system/trajectory-orbit-propag.service
sudo chmod 644 /etc/systemd/system/trajectory-orbit-propag.service
sudo systemd-analyze verify /etc/systemd/system/trajectory-orbit-propag.service   # sem saída = ok
sudo systemctl daemon-reload
sudo systemctl enable --now trajectory-orbit-propag
curl -sI http://127.0.0.1:8080 | head -1           # HTTP/1.1 200 OK
```

Se o app já estava instalado com o `install.sh --service` em outra pasta, pare o serviço antes (`sudo systemctl stop trajectory-orbit-propag`), copie para `/opt/TrajectoryOrbitPropag` o que houver de local na cópia antiga (`git status` mostra) e apague-a depois de conferir.

## 3. nginx e página inicial

```bash
sudo apt install -y nginx
sudo git clone https://github.com/francisvalguedes/orbittracking-servidor.git /opt/orbittracking-servidor
sudo /opt/orbittracking-servidor/scripts/instalar.sh nginx orbittracking.duckdns.org
```

Clonar não basta: o script é que copia a página para `/var/www/orbittracking`, instala os três sites em `/etc/nginx/sites-available/orbittracking-*.conf` com o domínio (passe o domínio puro, sem `http://` nem `www.`), desativa o site padrão do nginx, testa (`nginx -t`) e recarrega.

Confira os três antes do HTTPS:

```bash
curl -s http://orbittracking.duckdns.org | grep -o "<title>[^<]*"            # <title>Orbit Tracking
curl -s http://orbit.orbittracking.duckdns.org/api/meta | head -c 80; echo    # {"name":"orbit-tools",...
curl -s http://propag.orbittracking.duckdns.org | grep -o "<title>[^<]*"     # <title>Streamlit
```

## 4. HTTPS

Certificados gratuitos do Let's Encrypt, renovados automaticamente. Até aqui o navegador mostra "não seguro", o que é esperado.

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx --redirect \
  -d orbittracking.duckdns.org -d www.orbittracking.duckdns.org \
  -d orbit.orbittracking.duckdns.org -d propag.orbittracking.duckdns.org
sudo certbot certificates                           # um certificado com os quatro nomes
sudo certbot renew --dry-run                        # "all simulated renewals succeeded"
```

O certbot acrescenta o HTTPS e o redirecionamento de HTTP para HTTPS nos arquivos de `/etc/nginx/sites-available/`. Por isso o `instalar.sh` não sobrescreve esses arquivos sem `--sobrescrever`; se usar a opção, rode o certbot de novo.

Com HTTPS, a senha do Space-Track que os usuários digitam no orbit-tools viaja cifrada, e o botão "Copiar código" do navegador funciona.

## 5. Monitoramento

Um monitor **externo** (um monitor na própria VM cai junto com ela), por exemplo o plano gratuito do [UptimeRobot](https://uptimerobot.com), com três monitores HTTPS:

| Monitor | Endereço |
|---|---|
| Página inicial | `https://orbittracking.duckdns.org` |
| orbit-tools | `https://orbit.orbittracking.duckdns.org/api/meta` |
| TrajectoryOrbitPropag | `https://propag.orbittracking.duckdns.org` |

Ele avisa por e-mail se um app parar, se o DNS apontar para outro lugar ou, com o aviso de certificado ligado, se a renovação do certbot falhar. Os três fora do ar ao mesmo tempo indicam DNS ou VM; um só indica o app.

## Atualização

| O quê | Como |
|---|---|
| Página inicial | `cd /opt/orbittracking-servidor && sudo git pull && sudo scripts/instalar.sh site` |
| Sites do nginx (mudaram no repositório) | `sudo scripts/instalar.sh nginx orbittracking.duckdns.org --sobrescrever` e o `certbot` da seção 4 |
| orbit-tools | `cd /opt/orbit-tools && sudo -H -u mirante ./scripts/install-release.sh build-main && sudo systemctl restart orbit-tools` (guia do systemd do orbit-tools) |
| TrajectoryOrbitPropag | `sudo -u streamlit git -C /opt/TrajectoryOrbitPropag pull && sudo -H -u streamlit bash -c 'cd /opt/TrajectoryOrbitPropag && /usr/local/bin/uv sync --frozen' && sudo systemctl restart trajectory-orbit-propag` |
| Sistema | Atualizações de segurança automáticas (`unattended-upgrades`, ativo no Ubuntu da OCI); `sudo apt upgrade` de vez em quando |

## Segurança

- SSH só com chave (padrão da OCI); não ative login por senha.
- Abertas só as portas 22, 80 e 443; os apps em `127.0.0.1`, com usuários de serviço.
- Os apps são abertos a qualquer pessoa: não guardam dados de usuários, mas buscas pesadas ocupam a VM. Os limites `ORBIT_MAX_*` do orbit-tools seguram parte disso.
- Este repositório é público: nada de token do DuckDNS, chaves, certificados, `.env` nem coordenadas reais (o [.gitignore](.gitignore) bloqueia os nomes mais comuns).

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| Nada abre de fora | Portas 80/443 fechadas na Security List da OCI ou abaixo do `REJECT` no `iptables` da VM |
| Página "Welcome to nginx", ou `orbit.` abrindo a página inicial | O `instalar.sh nginx` não foi rodado (clonar não basta) |
| `502 Bad Gateway` num subdomínio | App parado: `systemctl status orbit-tools` ou `trajectory-orbit-propag`; log com `sudo journalctl -u <serviço> -n 30` |
| Serviço com `status=217/USER` | `User=` do serviço com um usuário que não existe |
| Serviço com `status=203/EXEC` | Programa do `ExecStart` não encontrado (ambiente Python não criado, ou linha quebrada no editor) |
| TrajectoryOrbitPropag fica em "Please wait..." ou "Connecting" | nginx sem os cabeçalhos de WebSocket (`Upgrade`, `Connection`) |
| Porta 80 abre o Streamlit em vez da página | Redirecionamento 80 → 8080 antigo no `iptables` (seção 1) |
| `certbot renew --dry-run`: "No simulated renewals were attempted" | Nenhum certificado emitido ainda: rode o `certbot --nginx` da seção 4 |
| `certbot` falha no desafio | Porta 80 fechada, ou o DuckDNS com outro IP |
| Navegador mostra "não seguro" | HTTPS ainda não configurado (seção 4) ou acesso por `http://` sem o `--redirect` |
| Monitor do orbit-tools com `405 Method Not Allowed`, site abrindo normal | O monitor usa HEAD e o orbit-tools instalado é anterior ao suporte a HEAD: atualize o orbit-tools ou use GET no monitor |
| Progresso do orbit-tools parado, resultado de uma vez | `proxy_buffering off` ausente no site do orbit-tools |
| App reinicia sozinho, `Out of memory` no `journalctl -k` | Sem swap (seção 1) |
