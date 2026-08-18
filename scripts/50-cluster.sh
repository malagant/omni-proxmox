#!/usr/bin/env bash
# Legt die MachineClasses an und erzeugt den Cluster aus dem Template.
# Wiederholtes Ausfuehren skaliert oder aktualisiert den bestehenden Cluster.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars CLUSTER_NAME TALOS_VERSION KUBERNETES_VERSION \
             CONTROL_PLANE_COUNT WORKER_COUNT PROXMOX_PROVIDER_ID \
             PVE_STORAGE_SELECTOR PVE_NETWORK_BRIDGE PVE_VLAN PVE_PLACEMENT_STRATEGY \
             CP_CORES CP_SOCKETS CP_MEMORY CP_DISK_SIZE \
             WORKER_CORES WORKER_SOCKETS WORKER_MEMORY WORKER_DISK_SIZE

ensure_omnictl

STAGE="${OUT_DIR}/cluster"
mkdir -p "${STAGE}"

# --- 1. MachineClasses -----------------------------------------------------
log "Rendere MachineClasses"

MC_ID="${CLUSTER_NAME}-controlplane" \
MC_CORES="${CP_CORES}" MC_SOCKETS="${CP_SOCKETS}" \
MC_MEMORY="${CP_MEMORY}" MC_DISK_SIZE="${CP_DISK_SIZE}" \
  render_template "${REPO_ROOT}/templates/machineclass.yaml.tmpl" \
                  "${STAGE}/machineclass-controlplane.yaml"

MC_ID="${CLUSTER_NAME}-worker" \
MC_CORES="${WORKER_CORES}" MC_SOCKETS="${WORKER_SOCKETS}" \
MC_MEMORY="${WORKER_MEMORY}" MC_DISK_SIZE="${WORKER_DISK_SIZE}" \
  render_template "${REPO_ROOT}/templates/machineclass.yaml.tmpl" \
                  "${STAGE}/machineclass-worker.yaml"

# Optionaler Proxmox-Pool. Steht nicht im Template, weil ein leerer Wert
# den Provider verwirren wuerde.
if [[ -n "${PVE_POOL:-}" ]]; then
  for f in "${STAGE}"/machineclass-*.yaml; do
    printf '      pool: "%s"\n' "${PVE_POOL}" >> "${f}"
  done
  ok "Proxmox-Pool '${PVE_POOL}' ergaenzt"
fi

ok "${STAGE}/machineclass-controlplane.yaml"
ok "${STAGE}/machineclass-worker.yaml"

log "Wende MachineClasses an"
omni apply -f "${STAGE}/machineclass-controlplane.yaml"
omni apply -f "${STAGE}/machineclass-worker.yaml"

# --- 2. Cluster-Template ---------------------------------------------------
log "Rendere Cluster-Template"
render_template "${REPO_ROOT}/templates/cluster.yaml.tmpl" "${STAGE}/cluster.yaml"
ok "${STAGE}/cluster.yaml"

log "Validiere"
omni cluster template validate -f "${STAGE}/cluster.yaml" \
  || die "Template ungueltig"
ok "Template gueltig"

# --- 3. Sync ---------------------------------------------------------------
echo
log "Erzeuge den Cluster (${CONTROL_PLANE_COUNT} Control Plane, ${WORKER_COUNT} Worker)"
dim "Omni fordert die VMs beim Proxmox-Provider an. Beim ersten Mal laedt"
dim "Proxmox zusaetzlich das Talos-ISO von factory.talos.dev — das dauert."
echo
omni cluster template sync -f "${STAGE}/cluster.yaml" --verbose \
  || die "Sync fehlgeschlagen"

echo
log "Warte, bis der Cluster bereit ist"
dim "Status live: ${OMNICTL} cluster template status -f ${STAGE}/cluster.yaml"
echo
if ! omni cluster template status -f "${STAGE}/cluster.yaml"; then
  warn "Cluster ist noch nicht bereit. Diagnose:"
  dim "  ${OMNICTL} get machines"
  dim "  ${OMNICTL} get machinestatus"
  dim "  ${OMNICTL} get clusterstatus ${CLUSTER_NAME}"
  dim "  Provider-Logs auf dem Host: docker compose -f ${OMNI_REMOTE_DIR}/provider/docker-compose.yaml logs"
fi

# --- 4. Zugangsdaten -------------------------------------------------------
KUBECONFIG_FILE="${REPO_ROOT}/${CLUSTER_NAME}.kubeconfig"
TALOSCONFIG_FILE="${REPO_ROOT}/${CLUSTER_NAME}.talosconfig"

log "Hole kubeconfig"
# Service-Account-Variante, damit die Datei ohne kubelogin-Plugin funktioniert.
# Die OIDC-Variante gaebe es mit: omnictl kubeconfig -c ${CLUSTER_NAME}
if omni kubeconfig "${KUBECONFIG_FILE}" \
     --cluster "${CLUSTER_NAME}" \
     --service-account --user omni-admin --groups system:masters \
     --merge=false --force 2>/dev/null; then
  chmod 600 "${KUBECONFIG_FILE}"
  ok "${KUBECONFIG_FILE}"
else
  warn "kubeconfig konnte noch nicht geholt werden — Cluster vermutlich noch nicht fertig"
fi

if omni talosconfig "${TALOSCONFIG_FILE}" --cluster "${CLUSTER_NAME}" --merge=false --force 2>/dev/null; then
  chmod 600 "${TALOSCONFIG_FILE}"
  ok "${TALOSCONFIG_FILE}"
fi

if [[ -s "${KUBECONFIG_FILE}" ]]; then
  echo
  log "Nodes"
  kubectl --kubeconfig "${KUBECONFIG_FILE}" get nodes -o wide 2>/dev/null \
    || warn "kubectl-Zugriff noch nicht moeglich"
fi

echo
ok "Fertig."
dim "Cluster:  export KUBECONFIG=${KUBECONFIG_FILE}"
dim "Talos:    export TALOSCONFIG=${TALOSCONFIG_FILE}"
dim "Skalieren: CONTROL_PLANE_COUNT/WORKER_COUNT in config/omni.env aendern,"
dim "           dann dieses Skript erneut ausfuehren."
