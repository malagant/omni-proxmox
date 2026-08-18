#!/usr/bin/env bash
# Baut wieder ab.
#
#   scripts/99-teardown.sh              # nur den Cluster (VMs werden in Proxmox geloescht)
#   scripts/99-teardown.sh --all        # zusaetzlich Provider und Omni-Stack

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars CLUSTER_NAME OMNI_SSH OMNI_REMOTE_DIR

ensure_omnictl

ALL=0
if [[ "${1:-}" == "--all" ]]; then ALL=1; fi

# --- 1. Cluster ------------------------------------------------------------
warn "Das loescht den Cluster '${CLUSTER_NAME}'. Omni faehrt die VMs in Proxmox herunter und entfernt sie."
read -rp "Cluster-Namen zur Bestaetigung eingeben: " confirm
[[ "${confirm}" == "${CLUSTER_NAME}" ]] || { log "Abgebrochen."; exit 0; }

CLUSTER_TEMPLATE="${OUT_DIR}/cluster/cluster.yaml"
if [[ -s "${CLUSTER_TEMPLATE}" ]]; then
  log "Loesche Cluster ueber das Template"
  omni cluster template delete -f "${CLUSTER_TEMPLATE}" --verbose \
    || warn "Loeschen ueber das Template fehlgeschlagen"
else
  log "Loesche Cluster ueber die Ressource"
  omni delete cluster "${CLUSTER_NAME}" || warn "Loeschen fehlgeschlagen"
fi

# MachineClasses bleiben sonst als Karteileichen zurueck.
for mc in "${CLUSTER_NAME}-controlplane" "${CLUSTER_NAME}-worker"; do
  omni delete machineclass "${mc}" 2>/dev/null && ok "MachineClass ${mc} entfernt" || true
done

ok "Cluster abgebaut"

if (( ALL == 0 )); then
  echo
  dim "Omni und der Provider laufen weiter. Vollstaendiger Abbau: --all"
  exit 0
fi

# --- 2. Provider und Omni --------------------------------------------------
echo
warn "Jetzt werden Provider und Omni-Stack auf ${OMNI_SSH} gestoppt und entfernt."
warn "Damit ist auch der Omni-Zustand weg (etcd, sqlite) — Cluster waeren nicht mehr verwaltbar."
read -rp "Wirklich? [j/N] " a
[[ "${a}" =~ ^[jJyY]$ ]] || { log "Abgebrochen."; exit 0; }

log "Stoppe den Provider"
on_host "cd '${OMNI_REMOTE_DIR}/provider' 2>/dev/null && docker compose down -v" || warn "Provider nicht gefunden"

log "Stoppe Omni"
on_host "cd '${OMNI_REMOTE_DIR}' 2>/dev/null && docker compose down -v" || warn "Omni nicht gefunden"

log "Entferne ${OMNI_REMOTE_DIR}"
on_host "rm -rf '${OMNI_REMOTE_DIR}'"

rm -f "${REPO_ROOT}/${CLUSTER_NAME}.kubeconfig" "${REPO_ROOT}/${CLUSTER_NAME}.talosconfig"
ok "abgebaut"

echo
warn "Lokal bleiben bestehen: secrets/, omniconfig.yaml, /etc/hosts-Eintrag und die CA im Schluesselbund."
dim "CA wieder entfernen (macOS):"
dim "  sudo security delete-certificate -c 'Omni Internal Root CA' /Library/Keychains/System.keychain"
