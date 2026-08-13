# Héberger `dsh` sur un VPS

Guide pas-à-pas pour faire tourner l'UI web de DeepSeek Harness sur un VPS OVH (ou tout autre serveur Linux), depuis les sources.

---

## 0. À lire avant de commencer

`dsh` est un **agent** : il exécute `bash` et écrit des fichiers sur la machine qui l'héberge. Exposer son port revient à donner un shell distant à quiconque atteint l'URL.

Le code du projet applique cette logique :

- le serveur écoute sur `127.0.0.1:3080` et **ne fournit ni TLS ni authentification** (`packages/host/webserver/README.md`) ;
- `dsh web --host 0.0.0.0` est **refusé volontairement** par le CLI — *« it would expose remote code execution to the network »* (`packages/bundle/web-app/src/startup.ts`) ;
- le serveur HTTP n'accepte que deux valeurs de bind, `127.0.0.1` et `0.0.0.0`, donc le seul bind atteignable via le CLI est la loopback.

**Conséquence :** on ne « publie » jamais `dsh` directement. On le laisse sur la loopback et on place devant, au choix, un tunnel SSH, `tailscale serve`, ou un reverse proxy avec TLS et authentification.

Deuxième point : l'agent tourne sous le même utilisateur Unix que le service, et ses outils peuvent lire `$DSH_HOME/.credentials.yaml` comme n'importe quel fichier de cet utilisateur (documenté dans `packages/credentials/credentials-local/README.md`). D'où l'utilisateur dédié `dsh` de ce guide : ne mettez rien d'autre de sensible sur ce compte.

---

## 1. Prérequis

| Élément | Recommandation |
|---|---|
| OS | Ubuntu 24.04 LTS (Debian 12 fonctionne aussi) |
| RAM | **4 Go minimum** pour le build ; 2 Go possible avec du swap (voir §3) |
| Disque | ~5 Go libres (`node_modules` + artefacts de build) |
| Node.js | `^22.19` ou `>=24` |
| pnpm | 11.7.0 (fourni par corepack) |
| Clé API | `DEEPSEEK_API_KEY` (ou un autre fournisseur, voir §5) |

Sur OVH, un VPS « Value » (2 vCore / 4 Go) suffit largement.

---

## 2. Installation automatisée

Le script `install-vps.sh` fait tout le §3 et §4 (utilisateur dédié, Node, pnpm, clone, build, service systemd). Sur le VPS, en root :

```sh
curl -fsSL https://raw.githubusercontent.com/qentinalouviers-sys/deepseek-harnyo/claude/tool-hosting-vps-xnr0lv/deploy/install-vps.sh -o install-vps.sh
less install-vps.sh          # lisez-le avant de l'exécuter
bash install-vps.sh
```

Si vous préférez comprendre chaque étape, suivez les sections manuelles ci-dessous — le script ne fait rien de plus.

---

## 3. Installation manuelle

### 3.1 Utilisateur dédié

```sh
sudo adduser --system --group --shell /bin/bash --home /home/dsh dsh
sudo mkdir -p /home/dsh/workspace /home/dsh/.dsh
sudo chown -R dsh:dsh /home/dsh
sudo chmod 700 /home/dsh/.dsh
```

`/home/dsh/workspace` est le répertoire de travail de l'agent : c'est là que vous déposerez les projets sur lesquels il doit intervenir.

### 3.2 Node.js 22 et pnpm

```sh
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs git build-essential
sudo corepack enable
node -v   # doit afficher v22.19 ou plus
```

### 3.3 Swap (uniquement si le VPS a moins de 4 Go de RAM)

Le build compile tout le monorepo TypeScript ; sans swap il se fait tuer par l'OOM killer sur un 2 Go.

```sh
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 3.4 Clone et build

```sh
sudo mkdir -p /opt/dsh && sudo chown dsh:dsh /opt/dsh
sudo -u dsh -H bash <<'EOF'
cd /opt/dsh
git clone https://github.com/qentinalouviers-sys/deepseek-harnyo.git deepseek-harness
cd deepseek-harness
pnpm install
pnpm run build
EOF
```

`pnpm run build` est obligatoire : le runner web de production a besoin des artefacts de paquets **et** du bundle frontend. Comptez 5 à 15 minutes selon le VPS.

Vérification rapide, toujours en tant que `dsh` :

```sh
sudo -u dsh -H node /opt/dsh/deepseek-harness/apps/cli/lib/bin.js web --help
```

---

## 4. Service systemd

```sh
sudo cp /opt/dsh/deepseek-harness/deploy/dsh-web.service /etc/systemd/system/
sudo cp /opt/dsh/deepseek-harness/deploy/service.env.example /home/dsh/.dsh/service.env
sudo chown dsh:dsh /home/dsh/.dsh/service.env
sudo chmod 600 /home/dsh/.dsh/service.env
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-web
systemctl status dsh-web
journalctl -u dsh-web -f
```

Le service doit afficher une ligne `dsh web: http://127.0.0.1:3080`.

Arrêt propre : `dsh` accorde 5 secondes à son arbre de plugins pour se démonter, et `SIGTERM` sort en code 0 — l'unité prévoit `TimeoutStopSec=15`.

---

## 5. Configurer le modèle

Deux options, selon le mode d'accès que vous choisirez au §6.

### Option A — via l'interface (mode tunnel uniquement)

Ouvrez **Settings → Models**, entrez la clé API DeepSeek, enregistrez. La clé est stockée dans `/home/dsh/.dsh/.credentials.yaml`, en `0600`. Prise en compte immédiate, sans redémarrage.

**Cette page ne fonctionne qu'en accès loopback** (voir §7).

### Option B — via fichiers (obligatoire en accès distant)

```sh
sudo -u dsh tee /home/dsh/.dsh/.credentials.yaml >/dev/null <<'EOF'
DEEPSEEK_API_KEY: sk-votre-cle-ici
EOF
sudo chmod 600 /home/dsh/.dsh/.credentials.yaml
```

Le format est une simple table clé/valeur, sans niveau d'emballage ni champ `version` — toute déviation est rejetée au boot plutôt qu'ignorée. Le fichier **doit** être en `0600` : un bit groupe ou autre le fait échouer avant lecture.

Pour changer de modèle par défaut, copiez `settings.example.yaml` :

```sh
sudo -u dsh cp /opt/dsh/deepseek-harness/deploy/settings.example.yaml /home/dsh/.dsh/settings.yaml
```

Les deux fichiers sont rechargés à chaud : une édition externe est publiée sans redémarrer le service.

> **Note sur `DEEPSEEK_API_KEY` en variable d'environnement.** Vous pouvez aussi la mettre dans `service.env`, mais l'environnement du processus est la couche **prioritaire et en lecture seule** : la page Settings refusera alors de l'écraser, et `describe()` la signalera comme non modifiable. Pour un serveur que vous administrerez aussi par l'UI, préférez `.credentials.yaml`.

---

## 6. Choisir un mode d'accès

### Mode A — Tunnel SSH (recommandé pour tester)

Rien à configurer côté serveur. Depuis **votre poste** :

```sh
ssh -N -L 3080:127.0.0.1:3080 root@VOTRE_IP_VPS
```

Puis ouvrez <http://127.0.0.1:3080>.

- Aucune exposition réseau, aucun port ouvert.
- **Toutes** les fonctions marchent, y compris Settings, les clés API et la gestion des presets — le navigateur envoie un `Host` loopback, qui passe le pare-feu applicatif sans restriction.
- C'est le mode à utiliser pour l'administration, même si vous configurez ensuite un accès public.

### Mode B — Tailscale (recommandé pour un usage régulier)

Accès permanent depuis vos appareils, sans ouvrir le moindre port public, avec HTTPS et identité fournis par Tailscale.

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo tailscale serve --bg 3080          # publie 127.0.0.1:3080 sur le tailnet en HTTPS
tailscale serve status                  # note le nom : vps.<tailnet>.ts.net
```

`tailscale serve` transmet le nom d'hôte du tailnet dans l'en-tête `Host`, qu'il faut déclarer à `dsh`. Dans `/home/dsh/.dsh/service.env` :

```sh
DSH_EXTRA_ARGS=--trusted-host vps.votre-tailnet.ts.net
```

puis `sudo systemctl restart dsh-web`.

### Mode C — Domaine public + HTTPS + authentification

À n'utiliser que si vous avez réellement besoin d'un accès depuis un navigateur quelconque. Voir §7 pour les limites, et §8 pour le durcissement.

Pointez un enregistrement DNS `A` vers l'IP du VPS, puis :

```sh
# Dépôt officiel Caddy : la version d'Ubuntu est plus ancienne et utilise
# encore la directive `basicauth` au lieu de `basic_auth`.
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy

caddy hash-password                     # génère le hash bcrypt à coller
sudo cp /opt/dsh/deepseek-harness/deploy/Caddyfile.example /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile          # remplacez le domaine et le hash
sudo systemctl reload caddy
```

(Une configuration nginx équivalente est fournie dans `nginx-dsh.conf.example` si vous préférez.)

Déclarez ensuite le domaine à `dsh`, dans `/home/dsh/.dsh/service.env` :

```sh
DSH_EXTRA_ARGS=--trusted-host dsh.votre-domaine.fr
```

`sudo systemctl restart dsh-web`, et n'oubliez pas le pare-feu :

```sh
sudo ufw allow 22,80,443/tcp
sudo ufw enable
```

Le port 3080 ne doit **jamais** être ouvert : le proxy l'atteint par la loopback.

---

## 7. Le pare-feu applicatif `/api` — ce qui marche et ce qui ne marche pas à distance

`dsh` filtre chaque requête `/api` sur l'en-tête `Host` (défense contre le DNS rebinding), avec deux règles supplémentaires quand des marqueurs navigateur sont présents : l'`Origin` doit correspondre exactement à l'autorité du `Host`, et un `sec-fetch-site: cross-site` explicite est refusé. C'est une **politique d'accessibilité, pas une authentification** — d'où l'obligation du mot de passe au §6.

Ce que cela implique concrètement :

1. **Le proxy doit transmettre le `Host` d'origine.** Caddy le fait par défaut ; nginx a besoin de `proxy_set_header Host $http_host;`. Les deux exemples fournis sont corrects.
2. **Le domaine servi doit être déclaré** via `--trusted-host`, sinon toutes les requêtes `/api` répondent `403` avant même d'atteindre le RPC.
3. **Un sous-ensemble de méthodes reste épinglé à la loopback**, même avec un `--trusted-host` valide. Elles répondront `403` en modes B et C :

| Méthode | Surface concernée |
|---|---|
| `settings.describe` / `update` / `replace` / `mutate` / `openDocument` | toute la page **Settings** |
| `credentials.describe` / `set` / `unset` | saisie des **clés API** |
| `host.pickDirectory`, `host.openPath` | sélecteur natif, ouverture de fichiers côté serveur |
| `agentPreset.read` / `copy` / `openDocument` / `remove` | édition des **presets d'agent** |

C'est délibéré : le plan de configuration reste local tant qu'il n'existe pas de vraie couche d'authentification dans le produit.

**Ce qui fonctionne normalement à distance :** création et reprise de sessions, prompts, historique, outils, plan, jobs, recherche, fork, renommage, export de session, choix du modèle (`session.models` / `session.selectModel`), liste et sélection des presets, et la **navigation de répertoires** — sur un VPS sans écran, le sélecteur de workspace bascule automatiquement en mode `browse`, servi par `host.listDirectory` / `host.createDirectory`, qui ne sont pas épinglés.

**En pratique :** administrez par le tunnel SSH (mode A), utilisez au quotidien le mode B ou C.

---

## 8. Durcissement

- **Jamais de port 3080 exposé.** Vérifiez : `sudo ss -tlnp | grep 3080` doit montrer `127.0.0.1:3080`.
- **Utilisateur dédié sans sudo.** L'agent exécute du code arbitraire sous cette identité.
- **Isolez le VPS.** Pas de clés SSH vers d'autres serveurs, pas d'identifiants cloud, pas de secrets applicatifs sur ce compte.
- **Permissions.** Les nouvelles sessions démarrent en preset `workspace-write` : bash et les mutations fichiers sont confinés au workspace et aux répertoires temporaires. En revanche **les lectures, l'accès réseau et la visibilité des processus ne sont pas confinés**. `DSH_PERMISSION_MODE` change le repli du processus.
- **Sauvegardes.** Les sessions vivent dans `$DSH_HOME` ; sauvegardez `/home/dsh/.dsh` si l'historique compte.
- **Télémétrie.** Désactivée par défaut. Ne l'activez pas à la légère : la base livrée n'a aucune règle de rédaction, les exports contiennent le texte des messages, les arguments d'outils et les chemins du workspace.

---

## 9. Exploitation

```sh
systemctl status dsh-web
journalctl -u dsh-web -f
journalctl -u dsh-web --since "1 hour ago"
sudo systemctl restart dsh-web
```

### Mettre à jour

```sh
sudo -u dsh -H bash <<'EOF'
cd /opt/dsh/deepseek-harness
git pull
pnpm install
pnpm run build
EOF
sudo systemctl restart dsh-web
```

Le lanceur ne vérifie pas la fraîcheur des bundles : un build oublié laisse tourner l'ancien code navigateur sans erreur.

### Dépannage

| Symptôme | Cause probable |
|---|---|
| `error: --host 0.0.0.0 is intentionally not supported` | Retirez ce flag ; utilisez un reverse proxy (§6) |
| Toutes les requêtes `/api` en `403` | `--trusted-host` absent ou ne correspondant pas au domaine réellement demandé |
| La page Settings en `403`, le reste fonctionne | Comportement attendu à distance (§7) — passez par le tunnel SSH |
| `MISSING_CREDENTIAL` | Clé absente de `.credentials.yaml` et de l'environnement |
| `UNKNOWN_MODEL` | Le modèle par défaut nomme un fournisseur non configuré |
| Build tué sans message | Mémoire insuffisante — ajoutez du swap (§3.3) |
| `EADDRINUSE` au démarrage | Le port 3080 est déjà pris ; changez `DSH_PORT` dans `service.env` |
| L'interface se charge mais reste figée | WebSocket bloqué par le proxy — vérifiez la configuration nginx (Caddy le gère seul) |
| Le fichier de credentials est refusé au boot | Permissions trop larges : `chmod 600` |

---

## Fichiers de ce dossier

| Fichier | Rôle |
|---|---|
| `install-vps.sh` | Installation complète automatisée (idempotente) |
| `dsh-web.service` | Unité systemd |
| `service.env.example` | Variables du service (port, flags, `DSH_HOME`) |
| `settings.example.yaml` | Modèle par défaut et fournisseurs |
| `credentials.example.yaml` | Format du document de clés API |
| `Caddyfile.example` | Reverse proxy Caddy : TLS automatique + auth basique |
| `nginx-dsh.conf.example` | Équivalent nginx, avec WebSocket et timeouts longs |
