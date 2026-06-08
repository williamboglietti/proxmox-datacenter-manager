#!/usr/bin/env bash
# Désactive le popup « No valid subscription » de Proxmox Datacenter Manager
# (bare-metal). À lancer en root.
#
# Usage :
#   bash disable-pdm-popup.sh             # applique
#   bash disable-pdm-popup.sh --persist   # + au démarrage et après apt
#   bash disable-pdm-popup.sh --revert    # annule
set -euo pipefail

INDEX="/usr/share/javascript/proxmox-datacenter-manager/index.hbs"
SELF="/usr/local/sbin/disable-pdm-popup.sh"
SERVICE="/etc/systemd/system/disable-pdm-popup.service"
APT_HOOK="/etc/apt/apt.conf.d/99-disable-pdm-popup"
SCRIPT_URL="https://raw.githubusercontent.com/williamboglietti/proxmox-datacenter-manager/main/scripts/disable-pdm-popup.sh"
# Source unique du correctif : le même fichier que celui embarqué dans l'image.
PATCH_URL="https://raw.githubusercontent.com/williamboglietti/proxmox-datacenter-manager/main/disable-subscription-nag.html"
MARKER="pdm-disable-subscription-nag"

log()  { echo "[pdm-popup] $*"; }
warn() { echo "[pdm-popup] AVERTISSEMENT : $*" >&2; }
die()  { echo "[pdm-popup] ERREUR : $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "à lancer en root."

restart_web() {
    if systemctl is-active --quiet proxmox-datacenter-api.service 2>/dev/null; then
        log "redémarrage de proxmox-datacenter-api.service"
        systemctl restart proxmox-datacenter-api.service
    fi
}

patch() {
    [ -f "$INDEX" ] || die "$INDEX introuvable — PDM est-il installé ici ?"
    if grep -q "BEGIN $MARKER" "$INDEX"; then
        log "déjà patché, rien à faire."
        return 0
    fi
    grep -q '</head>' "$INDEX" || die "pas de </head> dans index.hbs (format inattendu)."
    [ -f "$INDEX.orig" ] || { cp "$INDEX" "$INDEX.orig"; log "sauvegarde -> $INDEX.orig"; }

    # Récupère le correctif depuis le dépôt (source unique, identique à l'image)
    # et l'encadre de marqueurs BEGIN/END pour pouvoir le retirer (--revert).
    tmp="$(mktemp)"
    { echo "<!-- BEGIN $MARKER -->"; curl -fsSL "$PATCH_URL" || die "téléchargement du correctif échoué ($PATCH_URL)"; echo "<!-- END $MARKER -->"; } > "$tmp"

    awk -v patch="$tmp" '
        /<\/head>/ && !done { while ((getline l < patch) > 0) print l; close(patch); done=1 }
        { print }
    ' "$INDEX" > "$INDEX.new" && mv "$INDEX.new" "$INDEX"
    rm -f "$tmp"
    log "popup désactivé (patch injecté dans index.hbs)."
    restart_web
}

persist() {
    if [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
        install -m 0755 "${BASH_SOURCE[0]}" "$SELF"
    else
        curl -fsSL "$SCRIPT_URL" -o "$SELF" && chmod 0755 "$SELF"
    fi
    log "script installé -> $SELF"

    cat > "$SERVICE" <<EOF
[Unit]
Description=Désactive le popup d'abonnement Proxmox Datacenter Manager
# network-online : le correctif est téléchargé depuis le dépôt à l'exécution.
Wants=network-online.target
After=network-online.target proxmox-datacenter-api.service

[Service]
Type=oneshot
ExecStart=$SELF
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable disable-pdm-popup.service >/dev/null
    log "service systemd activé (réapplique au boot)."

    # proxmox-datacenter-manager-ui réécrit index.hbs à chaque MAJ : on réapplique.
    echo "DPkg::Post-Invoke { \"$SELF || true\"; };" > "$APT_HOOK"
    log "hook APT installé -> $APT_HOOK."
}

revert() {
    if [ -f "$INDEX" ] && grep -q "BEGIN $MARKER" "$INDEX"; then
        sed -i "/<!-- BEGIN $MARKER -->/,/<!-- END $MARKER -->/d" "$INDEX"
        log "patch retiré d'index.hbs."
    else
        warn "aucun patch trouvé dans index.hbs."
    fi
    [ -f "$INDEX.orig" ] && rm -f "$INDEX.orig"
    if [ -f "$SERVICE" ]; then
        systemctl disable disable-pdm-popup.service >/dev/null 2>&1 || true
        rm -f "$SERVICE"; systemctl daemon-reload
        log "service systemd retiré."
    fi
    [ -f "$APT_HOOK" ] && { rm -f "$APT_HOOK"; log "hook APT retiré."; }
    [ -f "$SELF" ]     && { rm -f "$SELF"; log "script local retiré."; }
    restart_web
}

case "${1:-}" in
    --persist) patch; persist ;;
    --revert)  revert ;;
    "")        patch ;;
    *)         die "argument inconnu : $1 (attendu : --persist | --revert | rien)" ;;
esac
log "terminé."
