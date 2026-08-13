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

# --- 2. Node.js -----------------------------------------------------------
# dsh exige ^22.19 || >=24.
node_ok=0
if command -v node >/dev/null; then
	major="$(node -p 'process.versions.node.split(".")[0]')"
	minor="$(node -p 'process.versions.node.split(".")[1]')"
	if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
		node_ok=1
	fi
fi

if [ "$node_ok" -eq 1 ]; then
	log "Node.js $(node -v) convient"
else
	log "Installation de Node.js ${NODE_MAJOR}.x"
	curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
	apt-get install -y nodejs
fi

log "Activation de corepack (pnpm)"
corepack enable

# --- 3. Swap si la RAM est juste -----------------------------------------
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

# --- 4. Utilisateur dédié -------------------------------------------------
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

# --- 6. Dépendances et build ---------------------------------------------
# `pnpm run build` est obligatoire : le runner web de production a besoin des
# artefacts de paquets ET du bundle frontend. Comptez 5 à 15 minutes.
# COREPACK_ENABLE_DOWNLOAD_PROMPT=0 : corepack télécharge la version de pnpm
# épinglée par le dépôt sans attendre une confirmation interactive.
run_as_dsh() { sudo -u "$DSH_USER" -H env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 bash -lc "$1"; }

log "Installation des dépendances (pnpm install)"
run_as_dsh "cd '$CHECKOUT' && pnpm install --frozen-lockfile"

log "Build (pnpm run build) — patientez"
run_as_dsh "cd '$CHECKOUT' && pnpm run build"

[ -f "${CHECKOUT}/apps/cli/lib/bin.js" ] || die "build incomplet : apps/cli/lib/bin.js absent"

# --- 7. Configuration du service -----------------------------------------
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
	-e "s#^ExecStart=/usr/bin/node#ExecStart=$(command -v node)#" \
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

# --- 8. Résumé ------------------------------------------------------------
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
