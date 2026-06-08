#!/bin/bash
# Point d'entrée du conteneur : démarre les deux daemons PDM sans systemd, sous tini (PID 1).
set -euo pipefail

log()  { echo "[pdm] $*"; }
warn() { echo "[pdm] WARNING: $*" >&2; }

BIN_DIR="/usr/libexec/proxmox"
CONFIG_DIR="/etc/proxmox-datacenter-manager"
DATA_DIR="/var/lib/proxmox-datacenter-manager"
LOG_DIR="/var/log/proxmox-datacenter-manager"
PRIV_SOCK="/run/proxmox-datacenter-manager/priv.sock"
PORT="${PDM_PORT:-8443}"

PRIV_API_PID=""
API_PID=""

cleanup() {
    log "Stopping PDM services..."
    [[ -n "$API_PID" ]]      && kill -TERM "$API_PID"      2>/dev/null || true
    [[ -n "$PRIV_API_PID" ]] && kill -TERM "$PRIV_API_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "Services stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- 1. Mot de passe root (root@pam), idempotent ------------------------------
PW_MARKER="$CONFIG_DIR/.root-pw-applied"
mkdir -p "$CONFIG_DIR"
if [[ -n "${PDM_ROOT_PASSWORD:-}" && ! -f "$PW_MARKER" ]]; then
    log "Setting root@pam password from PDM_ROOT_PASSWORD..."
    echo "root:${PDM_ROOT_PASSWORD}" | chpasswd
    touch "$PW_MARKER"
elif [[ ! -f "$PW_MARKER" ]]; then
    warn "PDM_ROOT_PASSWORD is not set. Set the password with:"
    warn "  docker exec -it <container> passwd   then   docker restart <container>"
fi

# --- 2. Permissions sur les volumes montés ------------------------------------
# PDM impose un owner/mode strict sur ces dossiers (vérifié par `setup`).
RUN_DIR="$(dirname "$PRIV_SOCK")"
mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"
chown www-data:www-data "$CONFIG_DIR"
chmod 1770 "$CONFIG_DIR"
chown root:www-data "$RUN_DIR"
chmod 1770 "$RUN_DIR"
chown root:www-data "$LOG_DIR"
chmod 0755 "$LOG_DIR"
chown -R www-data:www-data "$DATA_DIR"

# --- 3. Option : masquer le popup "Aucun abonnement en cours de validité" ------
INDEX_HBS="/usr/share/javascript/proxmox-datacenter-manager/index.hbs"
NAG_PATCH="/usr/local/share/pdm/disable-subscription-nag.html"
if [[ -f "$INDEX_HBS" ]]; then
    if [[ "${DISABLE_SUBSCRIPTION_NAG:-false}" == "true" ]]; then
        if ! grep -q "pdm-disable-subscription-nag" "$INDEX_HBS"; then
            log "DISABLE_SUBSCRIPTION_NAG=true: hiding the subscription dialog."
            cat "$NAG_PATCH" >> "$INDEX_HBS"
        fi
    elif grep -q "pdm-disable-subscription-nag" "$INDEX_HBS"; then
        # Toggle off : on retire le patch précédemment ajouté (du marqueur à la fin).
        log "DISABLE_SUBSCRIPTION_NAG disabled: removing the subscription patch."
        sed -i '/pdm-disable-subscription-nag/,$d' "$INDEX_HBS"
    fi
fi

# --- 3b. Option : désactiver le dépôt apt enterprise (401 sans abonnement) ------
# Le paquet container-meta ajoute pdm-enterprise.sources, inutile sur une install
# no-subscription : il fait échouer chaque `apt update` (401 Unauthorized).
ENTERPRISE_SOURCES="/etc/apt/sources.list.d/pdm-enterprise.sources"
if [[ -f "$ENTERPRISE_SOURCES" ]]; then
    if [[ "${DISABLE_ENTERPRISE_REPO:-false}" == "true" ]]; then
        if ! grep -q '^Enabled: no' "$ENTERPRISE_SOURCES"; then
            log "DISABLE_ENTERPRISE_REPO=true: disabling the enterprise apt repository."
            printf 'Enabled: no\n' >> "$ENTERPRISE_SOURCES"
        fi
    elif grep -q '^Enabled: no' "$ENTERPRISE_SOURCES"; then
        # Toggle off : on réactive le dépôt précédemment désactivé.
        log "DISABLE_ENTERPRISE_REPO disabled: re-enabling the enterprise apt repository."
        sed -i '/^Enabled: no$/d' "$ENTERPRISE_SOURCES"
    fi
fi

# --- 4. Génération clés/certs (sous-commande officielle, idempotente) ----------
# Remplace l'ExecStartPre systemd ; crée les clés d'auth et le certificat si absents.
log "Running PDM setup..."
"$BIN_DIR/proxmox-datacenter-privileged-api" setup

# --- 5. Daemon privilégié (root) ----------------------------------------------
log "Starting proxmox-datacenter-privileged-api..."
"$BIN_DIR/proxmox-datacenter-privileged-api" &
PRIV_API_PID=$!

log "Waiting for the privileged API socket ($PRIV_SOCK)..."
for _ in $(seq 1 30); do
    [[ -S "$PRIV_SOCK" ]] && break
    sleep 1
done
[[ -S "$PRIV_SOCK" ]] || warn "Privileged API socket missing after 30s, starting the API anyway."

# --- 6. Daemon API/UI (www-data) ----------------------------------------------
log "Starting proxmox-datacenter-api (www-data) on port ${PORT}..."
runuser -u www-data -- "$BIN_DIR/proxmox-datacenter-api" &
API_PID=$!

log "PDM is running - UI: https://localhost:${PORT}  (priv=$PRIV_API_PID, api=$API_PID)"

# --- 7. Si un daemon meurt, on arrête tout (Docker redémarre le conteneur) -----
wait -n "$PRIV_API_PID" "$API_PID" 2>/dev/null || true
warn "A PDM process exited unexpectedly. Shutting down."
cleanup
