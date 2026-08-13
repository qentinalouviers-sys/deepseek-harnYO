#!/usr/bin/env bash
#
# Installation de DeepSeek Harness (dsh) sur un VPS Debian/Ubuntu, depuis les
# sources, en service systemd écoutant sur la loopback.
#
# Le script est idempotent : le relancer met à jour le dépôt, rebuild et
# redémarre le service, sans toucher aux credentials ni aux settings existants.
#
# Il n'installe AUCUN reverse proxy et n'ouvre AUCUN port : le choix du mode
# d'accès (tunnel SSH, Tailscale, domaine public) vous revient — voir le §6 du
# README de ce dossier.
#
# Usage :
#   sudo bash install-vps.sh
#
# Variables surchargeables :
#   DSH_REPO_URL   dépôt à cloner
#   DSH_REF        branche ou tag à extraire
#   DSH_USER       utilisateur système dédié            (défaut: dsh)
#   DSH_PREFIX     racine d'installation                (défaut: /opt/dsh)
#   DSH_PORT       port d'écoute sur la loopback        (défaut: 3080)
#   DSH_SKIP_SWAP  =1 pour ne jamais créer de swap

set -euo pipefail

DSH_REPO_URL="${DSH_REPO_URL:-https://github.com/qentinalouviers-sys/deepseek-harnyo.git}"
DSH_REF="${DSH_REF:-claude/tool-hosting-vps-xnr0lv}"
DSH_USER="${DSH_USER:-dsh}"
DSH_PREFIX="${DSH_PREFIX:-/opt/dsh}"
DSH_PORT="${DSH_PORT:-3080}"
DSH_SKIP_SWAP="${DSH_SKIP_SWAP:-0}"

DSH_USER_HOME="/home/${DSH_USER}"
CHECKOUT="${DSH_PREFIX}/deepseek-harness"
DSH_HOME_DIR="${DSH_USER_HOME}/.dsh"
WORKSPACE="${DSH_USER_HOME}/workspace"
NODE_MAJOR=22

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "à lancer en root (sudo bash install-vps.sh)"
command -v apt-get >/dev/null || die "ce script cible Debian/Ubuntu (apt-get introuvable)"

# --- 1. Paquets système ---------------------------------------------------
log "Installation des paquets système"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3

# --- 2. Swap si la RAM est juste -----------------------------------------
# Le build compile tout le monorepo TypeScript ; sous 4 Go sans swap il se fait
# tuer par l'OOM killer.
mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
swap_mb="$(awk '/SwapTotal/ {print int($2/1024)}' /proc/meminfo)"
if [ "$DSH_SKIP_SWAP" != "1" ] && [ "$mem_mb" -lt 3500 ] && [ "$swap_mb" -lt 1024 ]; then
	log "RAM détectée : ${mem_mb} Mo — création d'un fichier d'échange de 4 Go"
	if [ ! -f /swapfile ]; then
		fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
		chmod 600 /swapfile
		mkswap /swapfile
	fi
	swapon /swapfile || warn "swapon a échoué, poursuite"
	grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# --- 3. Utilisateur dédié -------------------------------------------------
# L'agent exécute du code arbitraire sous cette identité : ne mettez rien
# d'autre de sensible sur ce compte.
if id -u "$DSH_USER" >/dev/null 2>&1; then
	log "L'utilisateur ${DSH_USER} existe déjà"
else
	log "Création de l'utilisateur système ${DSH_USER}"
	adduser --system --group --shell /bin/bash --home "$DSH_USER_HOME" "$DSH_USER"
fi

install -d -o "$DSH_USER" -g "$DSH_USER" -m 755 "$DSH_USER_HOME" "$WORKSPACE"
install -d -o "$DSH_USER" -g "$DSH_USER" -m 700 "$DSH_HOME_DIR"
install -d -o "$DSH_USER" -g "$DSH_USER" -m 755 "$DSH_PREFIX"

# --- 4. Node.js -----------------------------------------------------------
# dsh exige ^22.19 || >=24. La version ne suffit pas : le service tourne sous
# $DSH_USER, donc c'est SON accès qui décide. Un Node installé dans le home
# d'un autre compte (nvm, .hermes, fnm) est invisible à root près, et le
# service échouerait au démarrage.
#
SYS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Un candidat convient s'il satisfait la plage de versions ET si $DSH_USER peut
# l'exécuter. Un Node sous /home/<autre>/... échoue ici même si root le lance.
node_ok_for_service() {
	[ -n "${1:-}" ] || return 1
	sudo -u "$DSH_USER" -H "$1" -e '
		const [maj, min] = process.versions.node.split(".").map(Number)
		process.exit((maj === 22 && min >= 19) || maj >= 24 ? 0 : 1)
	' >/dev/null 2>&1
}

# Le PATH système d'abord (c'est celui que verra systemd), puis le node de root,
# qui peut vivre ailleurs — /opt/... est légitime, un home ne l'est pas.
NODE_BIN=''
for candidate in \
	"$(sudo -u "$DSH_USER" -H env PATH="$SYS_PATH" bash -c 'command -v node' 2>/dev/null || true)" \
	"$(command -v node 2>/dev/null || true)"
do
	if node_ok_for_service "$candidate"; then
		NODE_BIN="$candidate"
		break
	fi
done

if [ -z "$NODE_BIN" ]; then
	log "Node absent ou inaccessible à ${DSH_USER} — installation système de Node ${NODE_MAJOR}.x"
	curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
	apt-get install -y nodejs
	NODE_BIN="$(sudo -u "$DSH_USER" -H env PATH="$SYS_PATH" bash -c 'command -v node' 2>/dev/null || true)"
	node_ok_for_service "$NODE_BIN" || die "Node toujours inaccessible à ${DSH_USER} après installation"
fi

log "Node du service : ${NODE_BIN} ($(sudo -u "$DSH_USER" -H "$NODE_BIN" -v))"

# Le répertoire de node rejoint le PATH des commandes lancées sous $DSH_USER :
# le shebang `#!/usr/bin/env node` de pnpm doit le trouver.
RUN_PATH="$(dirname "$NODE_BIN"):${SYS_PATH}"

# `bash -c` et non `-lc` : sourcer les profils réintroduirait un Node de home.
run_as_dsh() {
	sudo -u "$DSH_USER" -H env PATH="$RUN_PATH" COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -c "$1"
}

# --- 5. Clone ou mise à jour ---------------------------------------------
if [ -d "${CHECKOUT}/.git" ]; then
	log "Mise à jour du dépôt (${DSH_REF})"
	sudo -u "$DSH_USER" -H git -C "$CHECKOUT" fetch --prune origin
	sudo -u "$DSH_USER" -H git -C "$CHECKOUT" checkout "$DSH_REF"
	sudo -u "$DSH_USER" -H git -C "$CHECKOUT" pull --ff-only origin "$DSH_REF"
else
	log "Clone de ${DSH_REPO_URL} (${DSH_REF})"
	sudo -u "$DSH_USER" -H git clone --branch "$DSH_REF" "$DSH_REPO_URL" "$CHECKOUT"
fi

# --- 6. pnpm --------------------------------------------------------------
# La version est lue depuis le champ `packageManager` du dépôt, donc elle suit
# le pin du projet sans être recopiée ici.
#
# corepack est délibérément écarté : `corepack prepare` dépose sa copie de pnpm
# dans le cache de l'utilisateur qui l'exécute, donc une activation par root
# reste inutilisable par le compte de service. L'archive du registre npm est
# installée une fois pour toutes sous /usr/local, lisible par tous, et pnpm
# étant du JavaScript pur, elle convient à toutes les architectures.
#
# `apt-get install npm` est également écarté : sur Ubuntu récent ce paquet peut
# tirer sa propre version de Node et entrer en conflit avec celle installée.
PNPM_PIN="$("$NODE_BIN" -p "((require('${CHECKOUT}/package.json').packageManager)||'pnpm@11.7.0').split('@').pop()")"

log "Installation de pnpm ${PNPM_PIN} depuis le registre npm"
pnpm_tmp="$(mktemp -d)"
curl -fsSL "https://registry.npmjs.org/pnpm/-/pnpm-${PNPM_PIN}.tgz" -o "${pnpm_tmp}/pnpm.tgz" \
	|| die "téléchargement de pnpm ${PNPM_PIN} échoué"
rm -rf /usr/local/lib/pnpm
mkdir -p /usr/local/lib/pnpm
tar -xzf "${pnpm_tmp}/pnpm.tgz" -C /usr/local/lib/pnpm --strip-components=1
rm -rf "$pnpm_tmp"
chmod -R a+rX /usr/local/lib/pnpm
chmod 755 /usr/local/lib/pnpm/bin/pnpm.mjs
ln -sf /usr/local/lib/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm

# Invocation par chemin absolu, jamais par le PATH : un autre pnpm placé plus
# tôt (shim corepack, installation globale) le masquerait, et un shim de
# version différente tenterait de retélécharger le pin par le réseau.
PNPM_RUN="'${NODE_BIN}' /usr/local/lib/pnpm/bin/pnpm.mjs"

# Vérifié sous l'identité du service : c'est ce couple qui exécutera le build.
# L'erreur de pnpm n'est pas masquée — elle est la seule information utile si
# cette vérification échoue.
if ! pnpm_version="$(run_as_dsh "${PNPM_RUN} --version")"; then
	die "pnpm inutilisable par ${DSH_USER} — voir l'erreur ci-dessus"
fi
log "pnpm utilisé par ${DSH_USER} : ${pnpm_version}"

# --- 7. Dépendances et build ---------------------------------------------
# `pnpm run build` est obligatoire : le runner web de production a besoin des
# artefacts de paquets ET du bundle frontend. Comptez 5 à 20 minutes.

log "Installation des dépendances (pnpm install)"
run_as_dsh "cd '$CHECKOUT' && ${PNPM_RUN} install --frozen-lockfile"

log "Build (pnpm run build) — patientez"
run_as_dsh "cd '$CHECKOUT' && ${PNPM_RUN} run build"

[ -f "${CHECKOUT}/apps/cli/lib/bin.js" ] || die "build incomplet : apps/cli/lib/bin.js absent"

# --- 8. Configuration du service -----------------------------------------
if [ ! -f "${DSH_HOME_DIR}/service.env" ]; then
	log "Création de ${DSH_HOME_DIR}/service.env"
	install -o "$DSH_USER" -g "$DSH_USER" -m 600 \
		"${CHECKOUT}/deploy/service.env.example" "${DSH_HOME_DIR}/service.env"
	sed -i "s/^DSH_PORT=.*/DSH_PORT=${DSH_PORT}/" "${DSH_HOME_DIR}/service.env"
else
	log "service.env existant conservé"
fi

log "Installation de l'unité systemd"
unit=/etc/systemd/system/dsh-web.service
sed -e "s#^User=.*#User=${DSH_USER}#" \
	-e "s#^Group=.*#Group=${DSH_USER}#" \
	-e "s#^WorkingDirectory=.*#WorkingDirectory=${WORKSPACE}#" \
	-e "s#Environment=HOME=.*#Environment=HOME=${DSH_USER_HOME}#" \
	-e "s#Environment=DSH_HOME=.*#Environment=DSH_HOME=${DSH_HOME_DIR}#" \
	-e "s#^EnvironmentFile=.*#EnvironmentFile=-${DSH_HOME_DIR}/service.env#" \
	-e "s#/opt/dsh/deepseek-harness#${CHECKOUT}#" \
	-e "s#^ExecStart=/usr/bin/node#ExecStart=${NODE_BIN}#" \
	"${CHECKOUT}/deploy/dsh-web.service" >"$unit"

systemctl daemon-reload
systemctl enable dsh-web >/dev/null
systemctl restart dsh-web

sleep 3
if ! systemctl is-active --quiet dsh-web; then
	warn "le service n'est pas actif — journal des dernières lignes :"
	journalctl -u dsh-web -n 40 --no-pager >&2
	die "démarrage échoué"
fi

# --- 9. Résumé ------------------------------------------------------------
cat <<EOF

$(log "Installation terminée")

  Service   : dsh-web (actif, écoute sur 127.0.0.1:${DSH_PORT})
  Sources   : ${CHECKOUT}
  DSH_HOME  : ${DSH_HOME_DIR}
  Workspace : ${WORKSPACE}

Étape suivante — la clé API :

  sudo -u ${DSH_USER} tee ${DSH_HOME_DIR}/.credentials.yaml >/dev/null <<'KEY'
  DEEPSEEK_API_KEY: sk-votre-cle-ici
KEY
  sudo chmod 600 ${DSH_HOME_DIR}/.credentials.yaml

Étape suivante — l'accès. Le port ${DSH_PORT} n'est PAS exposé, et ne doit pas
l'être : dsh exécute bash sur cette machine et ne fournit ni TLS ni mot de passe.

  Pour tester tout de suite, depuis VOTRE poste :
      ssh -N -L ${DSH_PORT}:127.0.0.1:${DSH_PORT} root@<ip-du-vps>
  puis ouvrez http://127.0.0.1:${DSH_PORT}

  Pour un accès permanent (Tailscale ou domaine public + TLS + mot de passe),
  suivez ${CHECKOUT}/deploy/README.md §6.

Journal : journalctl -u dsh-web -f

EOF
