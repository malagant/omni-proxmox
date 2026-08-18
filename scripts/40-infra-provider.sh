#!/usr/bin/env bash
# Registriert den Proxmox-Infra-Provider bei Omni und startet ihn auf dem
# Omni-Host. Danach kann Omni VMs in Proxmox selbst anlegen und wieder loeschen.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars OMNI_SSH OMNI_ENDPOINT OMNI_HOST_IP OMNI_REMOTE_DIR \
             PROXMOX_PROVIDER_ID PROXMOX_PROVIDER_VERSION PROXMOX_URL

need_cmd rsync
ensure_omnictl

KEY_FILE="${SECRETS_DIR}/infra-provider-key"
STAGE="${OUT_DIR}/proxmox-provider"
REMOTE_DIR="${OMNI_REMOTE_DIR}/provider"

[[ -s "${SECRETS_DIR}/ca.pem" ]] || die "secrets/ca.pem fehlt — erst scripts/10-secrets.sh ausfuehren"

# --- 1. Infra-Provider-Key -------------------------------------------------
# Achtung: das ist ein Infra-Provider-Key, kein normaler Service-Account-Key.
# Der Provider lehnt letzteren ab.
if [[ -s "${KEY_FILE}" ]]; then
  ok "Infra-Provider-Key existiert bereits (secrets/infra-provider-key)"
else
  log "Registriere Infra-Provider '${PROXMOX_PROVIDER_ID}' bei Omni"
  CREATE_OUT="$(omni infraprovider create "${PROXMOX_PROVIDER_ID}" 2>&1)" \
    || { echo "${CREATE_OUT}"; die "omnictl infraprovider create fehlgeschlagen"; }

  KEY="$(echo "${CREATE_OUT}" | sed -n 's/^OMNI_SERVICE_ACCOUNT_KEY=//p' | tr -d '\r\n')"
  [[ -n "${KEY}" ]] || { echo "${CREATE_OUT}"; die "Kein OMNI_SERVICE_ACCOUNT_KEY in der Ausgabe gefunden"; }

  printf '%s' "${KEY}" > "${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
  ok "${KEY_FILE}"
fi

INFRA_PROVIDER_KEY="$(cat "${KEY_FILE}")"
export INFRA_PROVIDER_KEY

# --- 2. Provider-Konfiguration ---------------------------------------------
log "Rendere Provider-Stack nach ${STAGE}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"

# Token-Auth wenn moeglich, sonst Benutzer/Passwort.
{
  echo "# Generiert von scripts/40-infra-provider.sh"
  echo "proxmox:"
  echo "  url: \"${PROXMOX_URL}\""
  if [[ -n "${PROXMOX_TOKEN_SECRET:-}" ]]; then
    require_vars PROXMOX_TOKEN_ID
    echo "  tokenID: \"${PROXMOX_TOKEN_ID}\""
    echo "  tokenSecret: \"${PROXMOX_TOKEN_SECRET}\""
  else
    require_vars PROXMOX_USERNAME PROXMOX_PASSWORD PROXMOX_REALM
    echo "  username: \"${PROXMOX_USERNAME}\""
    echo "  password: \"${PROXMOX_PASSWORD}\""
    echo "  realm: \"${PROXMOX_REALM}\""
  fi
  echo "  insecureSkipVerify: ${PROXMOX_INSECURE_SKIP_VERIFY:-true}"
} > "${STAGE}/config.yaml"
chmod 600 "${STAGE}/config.yaml"

render_template "${REPO_ROOT}/stack/provider-compose.yaml.tmpl" "${STAGE}/docker-compose.yaml"
cp "${SECRETS_DIR}/ca.pem" "${STAGE}/ca.pem"
ok "gerendert"

# --- 3. Ausrollen ----------------------------------------------------------
log "Kopiere nach ${OMNI_SSH}:${REMOTE_DIR}"
ensure_host_dir "${REMOTE_DIR}"
rsync -a --delete -e "ssh -o StrictHostKeyChecking=accept-new" \
  "${STAGE}/" "${OMNI_SSH}:${REMOTE_DIR}/"
on_host "chmod 700 '${REMOTE_DIR}' && chmod 600 '${REMOTE_DIR}/config.yaml'"

detect_host_docker

log "Starte den Provider"
on_host "cd '${REMOTE_DIR}' && ${HOST_DOCKER} compose pull --quiet && ${HOST_DOCKER} compose up -d"

# --- 4. Verifizieren -------------------------------------------------------
provider_registered() {
  omni get infraproviderstatus "${PROXMOX_PROVIDER_ID}" 2>/dev/null | grep -q "${PROXMOX_PROVIDER_ID}"
}

if wait_for 180 "Registrierung des Providers bei Omni" provider_registered; then
  omni get infraproviderstatus "${PROXMOX_PROVIDER_ID}" || true
else
  warn "Provider hat sich nicht registriert. Logs:"
  on_host "cd '${REMOTE_DIR}' && ${HOST_DOCKER} compose logs --tail=50" || true
  echo
  dim "Haeufige Ursachen:"
  dim "  - Falscher Key-Typ: es muss ein Infra-Provider-Key sein, kein Service-Account-Key"
  dim "  - Provider traut dem Omni-Zertifikat nicht: ca.pem pruefen"
  dim "  - ${OMNI_ENDPOINT} loest im Container nicht auf: extra_hosts pruefen"
  die "Abbruch"
fi

echo
ok "Proxmox-Provider laeuft."
dim "Naechster Schritt: scripts/50-cluster.sh"
