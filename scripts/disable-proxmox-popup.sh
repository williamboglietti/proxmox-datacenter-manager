#!/usr/bin/env bash
# Désactive le popup « No valid subscription » de Proxmox VE / Backup Server
# (bare-metal). À lancer en root.
#
# Usage :
#   bash disable-proxmox-popup.sh             # applique
#   bash disable-proxmox-popup.sh --persist   # + au démarrage et après apt
#   bash disable-proxmox-popup.sh --revert    # annule
set -euo pipefail

JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
SELF="/usr/local/sbin/disable-proxmox-popup.sh"
SERVICE="/etc/systemd/system/disable-proxmox-popup.service"
APT_HOOK="/etc/apt/apt.conf.d/99-disable-proxmox-popup"
SCRIPT_URL="https://raw.githubusercontent.com/williamboglietti/proxmox-datacenter-manager/main/scripts/disable-proxmox-popup.sh"

UNPATCHED="\.data\.status\.toLowerCase() !== 'active'"
PATCHED=".data.status.toLowerCase() === 'active'"

log()  { echo "[popup] $*"; }
warn() { echo "[popup] AVERTISSEMENT : $*" >&2; }
die()  { echo "[popup] ERREUR : $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "à lancer en root."

restart_web() {
    for svc in pveproxy.service proxmox-backup-proxy.service; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "redémarrage de $svc"
            systemctl restart "$svc"
        fi
    done
}

patch() {
    [ -f "$JS" ] || die "$JS introuvable — PVE/PBS est-il installé ici ?"
    if ! grep -q "$UNPATCHED" "$JS"; then
        if grep -qF "$PATCHED" "$JS"; then
            log "déjà patché, rien à faire."
            return 0
        fi
        die "motif d'abonnement introuvable dans proxmoxlib.js (version non supportée ?)."
    fi
    # Sauvegarde de l'original UNE SEULE FOIS (ne pas l'écraser au re-run).
    [ -f "$JS.orig" ] || { cp "$JS" "$JS.orig"; log "sauvegarde -> $JS.orig"; }
    sed -i "s/$UNPATCHED/$PATCHED/g" "$JS"
    log "popup désactivé."
    restart_web
}

persist() {
    # Copie locale du script (pour le service boot + le hook apt).
    if [ -f "${BASH_SOURCE[0]}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
        install -m 0755 "${BASH_SOURCE[0]}" "$SELF"
    else
        curl -fsSL "$SCRIPT_URL" -o "$SELF" && chmod 0755 "$SELF"
    fi
    log "script installé -> $SELF"

    cat > "$SERVICE" <<EOF
[Unit]
Description=Désactive le popup d'abonnement Proxmox (PVE/PBS)
After=network.target pveproxy.service proxmox-backup-proxy.service

[Service]
Type=oneshot
ExecStart=$SELF
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable disable-proxmox-popup.service >/dev/null
    log "service systemd activé (réapplique au boot)."

    # Réapplique après chaque mise à jour de paquet (proxmox-widget-toolkit
    # réécrit proxmoxlib.js). '|| true' : ne bloque jamais apt.
    echo "DPkg::Post-Invoke { \"$SELF || true\"; };" > "$APT_HOOK"
    log "hook APT installé -> $APT_HOOK (réapplique après apt)."
}

revert() {
    if [ -f "$JS.orig" ]; then
        mv "$JS.orig" "$JS"
        log "proxmoxlib.js restauré depuis .orig"
    else
        warn "pas de $JS.orig — restauration ignorée (réinstaller proxmox-widget-toolkit si besoin)."
    fi
    if [ -f "$SERVICE" ]; then
        systemctl disable disable-proxmox-popup.service >/dev/null 2>&1 || true
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
