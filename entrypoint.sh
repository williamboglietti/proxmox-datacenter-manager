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
JOURNALD_PID=""

cleanup() {
    log "Stopping PDM services..."
    [[ -n "$API_PID" ]]      && kill -TERM "$API_PID"      2>/dev/null || true
    [[ -n "$PRIV_API_PID" ]] && kill -TERM "$PRIV_API_PID" 2>/dev/null || true
    [[ -n "$JOURNALD_PID" ]] && kill -TERM "$JOURNALD_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    log "Services stopped."
    exit 0
}

# Route la sortie d'un daemon vers stdout (docker logs) ET le journal (onglet UI).
# stdbuf -oL : line-buffering pour que `docker logs` reste réactif (le pipe tee
# serait sinon bufferisé par blocs).
run_logged() {
    local tag="$1"; shift
    "$@" > >(stdbuf -oL tee >(systemd-cat -t "$tag")) 2>&1 &
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

# --- 3. Options : patches HTML optionnels injectés dans index.hbs --------------
# Chaque patch est encadré par des marqueurs BEGIN/END pour pouvoir l'ajouter et
# le retirer indépendamment des autres (toggles idempotents).
INDEX_HBS="/usr/share/javascript/proxmox-datacenter-manager/index.hbs"
NAG_PATCH="/usr/local/share/pdm/disable-subscription-nag.html"
UPDATES_PATCH="/usr/local/share/pdm/disable-updates-tab.html"
POWER_PATCH="/usr/local/share/pdm/disable-power-buttons.html"
SUB_PANEL_PATCH="/usr/local/share/pdm/disable-subscription-panel.html"

apply_html_patch() { # $1=marqueur $2=fichier
    [[ -f "$INDEX_HBS" && -f "$2" ]] || return 0
    grep -q "BEGIN $1" "$INDEX_HBS" && return 0
    local tmp; tmp="$(mktemp)"
    { echo "<!-- BEGIN $1 -->"; cat "$2"; echo "<!-- END $1 -->"; } > "$tmp"
    # Insérer dans le <head> : l'UI (Yew/WASM) réécrit le <body> au démarrage,
    # ce qui effacerait un <style> placé là ; le <head> est préservé. Un patch
    # après </html> n'est pas appliqué du tout. Fallback append si pas de </head>.
    if grep -q '</head>' "$INDEX_HBS"; then
        awk -v patch="$tmp" '
            /<\/head>/ && !done { while ((getline l < patch) > 0) print l; close(patch); done=1 }
            { print }
        ' "$INDEX_HBS" > "$INDEX_HBS.tmp" && mv "$INDEX_HBS.tmp" "$INDEX_HBS"
    else
        cat "$tmp" >> "$INDEX_HBS"
    fi
    rm -f "$tmp"
}
remove_html_patch() { # $1=marqueur
    [[ -f "$INDEX_HBS" ]] || return 0
    grep -q "BEGIN $1" "$INDEX_HBS" || return 0
    sed -i "/<!-- BEGIN $1 -->/,/<!-- END $1 -->/d" "$INDEX_HBS"
}

# 3a. Masquer le popup "Aucun abonnement en cours de validité".
if [[ "${DISABLE_SUBSCRIPTION_NAG:-false}" == "true" ]]; then
    log "DISABLE_SUBSCRIPTION_NAG=true: hiding the subscription dialog."
    apply_html_patch "pdm-disable-subscription-nag" "$NAG_PATCH"
else
    remove_html_patch "pdm-disable-subscription-nag"
fi

# 3b. Masquer l'onglet "Mises à jour" (les MAJ se font par image, pas par apt).
# Défaut "true" : un upgrade apt depuis cet onglet casserait le conteneur.
if [[ "${DISABLE_UPDATES_TAB:-true}" == "true" ]]; then
    log "DISABLE_UPDATES_TAB=true: hiding the Updates tab."
    apply_html_patch "pdm-disable-updates-tab" "$UPDATES_PATCH"
else
    remove_html_patch "pdm-disable-updates-tab"
fi

# 3c. Masquer les boutons "Redémarrer"/"Arrêter" (cycle de vie géré par Docker).
# Défaut "true" : ils appellent systemctl reboot/poweroff, indisponible ici.
if [[ "${DISABLE_POWER_BUTTONS:-true}" == "true" ]]; then
    log "DISABLE_POWER_BUTTONS=true: hiding the Reboot/Shutdown buttons."
    apply_html_patch "pdm-disable-power-buttons" "$POWER_PATCH"
else
    remove_html_patch "pdm-disable-power-buttons"
fi

# 3d. Masquer l'entrée de menu "Abonnement" locale (inutile sur ce conteneur).
# Défaut "true" ; ne touche pas à "Subscription Registry" (gestion des remotes).
if [[ "${DISABLE_SUBSCRIPTION_PANEL:-true}" == "true" ]]; then
    log "DISABLE_SUBSCRIPTION_PANEL=true: hiding the Subscription menu entry."
    apply_html_patch "pdm-disable-subscription-panel" "$SUB_PANEL_PATCH"
else
    remove_html_patch "pdm-disable-subscription-panel"
fi

# --- 4. journald standalone (alimente l'onglet « Journal système » de l'UI) ----
# Sans systemd, aucun journal n'est tenu : journalctl renvoie [] et l'UI affiche
# « invalid response: [] ». Démarré AVANT le setup pour que /dev/log existe
# (sinon le setup logue « Unable to open syslog »).
log "Starting systemd-journald..."
mkdir -p /run/systemd/journal
/lib/systemd/systemd-journald &
JOURNALD_PID=$!
for _ in $(seq 1 10); do
    [[ -S /run/systemd/journal/dev-log ]] && break
    sleep 0.5
done
if [[ -S /run/systemd/journal/dev-log ]]; then
    ln -sf /run/systemd/journal/dev-log /dev/log
else
    warn "journald socket missing; the System Log tab may stay empty."
fi

# --- 4b. Génération clés/certs (sous-commande officielle, idempotente) ----------
# Remplace l'ExecStartPre systemd ; crée les clés d'auth et le certificat si absents.
log "Running PDM setup..."
"$BIN_DIR/proxmox-datacenter-privileged-api" setup

# --- 5. Daemon privilégié (root) ----------------------------------------------
log "Starting proxmox-datacenter-privileged-api..."
run_logged proxmox-datacenter-privileged-api "$BIN_DIR/proxmox-datacenter-privileged-api"
PRIV_API_PID=$!

log "Waiting for the privileged API socket ($PRIV_SOCK)..."
for _ in $(seq 1 30); do
    [[ -S "$PRIV_SOCK" ]] && break
    sleep 1
done
[[ -S "$PRIV_SOCK" ]] || warn "Privileged API socket missing after 30s, starting the API anyway."

# --- 6. Daemon API/UI (www-data) ----------------------------------------------
log "Starting proxmox-datacenter-api (www-data) on port ${PORT}..."
run_logged proxmox-datacenter-api runuser -u www-data -- "$BIN_DIR/proxmox-datacenter-api"
API_PID=$!

log "PDM is running - UI: https://localhost:${PORT}  (priv=$PRIV_API_PID, api=$API_PID)"

# --- 7. Si un daemon meurt, on arrête tout (Docker redémarre le conteneur) -----
wait -n "$PRIV_API_PID" "$API_PID" 2>/dev/null || true
warn "A PDM process exited unexpectedly. Shutting down."
cleanup
