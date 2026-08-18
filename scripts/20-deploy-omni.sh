#!/usr/bin/env bash
# Rendert den Omni-Stack, kopiert ihn auf den Omni-Host und startet ihn.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars OMNI_HOST_IP OMNI_ENDPOINT AUTH_ENDPOINT OMNI_USER_EMAIL \
             OMNI_REMOTE_DIR OMNI_VERSION DEX_VERSION

need_cmd rsync
need_cmd ssh

STAGE="${OUT_DIR}/omni-host"

# --- 1. Geheimnisse einlesen ----------------------------------------------
for f in ca.pem server-key.pem server-chain.pem omni.asc dex-password.hash dex-client-secret; do
  if [[ ! -e "${SECRETS_DIR}/${f}" ]]; then
    die "secrets/${f} fehlt — erst scripts/10-secrets.sh ausfuehren"
  elif [[ ! -r "${SECRETS_DIR}/${f}" ]]; then
    # Typisch, wenn 10-secrets.sh mit sudo lief: die Dateien gehoeren dann root
    # und haben Modus 600.
    die "secrets/${f} ist nicht lesbar. Frueherer Lauf mit sudo?
     Reparieren:  sudo chown -R $(id -un) '${SECRETS_DIR}'"
  fi
done

DEX_PASSWORD_HASH="$(cat "${SECRETS_DIR}/dex-password.hash")"
DEX_CLIENT_SECRET="$(cat "${SECRETS_DIR}/dex-client-secret")"
export DEX_PASSWORD_HASH DEX_CLIENT_SECRET

# --- 2. Stack rendern ------------------------------------------------------
# Liefert HOST_UID/HOST_GID — das Compose-Template braucht sie fuer den
# dex-Container, der sonst den privaten Schluessel nicht lesen kann.
detect_host_privileges

log "Rendere Stack nach ${STAGE}"
reset_stage_dir "${STAGE}"
mkdir -p "${STAGE}/secrets" "${STAGE}/sqlite"

# dex.yaml zuerst: aus ihrem Inhalt entsteht eine Pruefsumme, die als Label in
# die Compose-Datei geht. Ohne die wuerde eine geaenderte dex.yaml keinen
# Neustart ausloesen — sie ist ein Bind-Mount, und Compose sieht nur die
# Service-Definition. Ein neues Passwort waere sonst wirkungslos.
render_template "${REPO_ROOT}/stack/dex.yaml.tmpl" "${STAGE}/dex.yaml"
DEX_CONFIG_SHA="$(openssl dgst -sha256 "${STAGE}/dex.yaml" | awk '{print $NF}' | cut -c1-16)"
export DEX_CONFIG_SHA

render_template "${REPO_ROOT}/stack/docker-compose.yaml.tmpl" "${STAGE}/docker-compose.yaml"

# Ohne EULA-Angaben die Flags entfernen — Omni lehnt leere Werte ab.
if [[ -z "${EULA_NAME:-}" || -z "${EULA_EMAIL:-}" ]]; then
  sed -i.bak '/--eula-accept-/d' "${STAGE}/docker-compose.yaml"
  rm -f "${STAGE}/docker-compose.yaml.bak"
  warn "EULA-Flags weggelassen — beim ersten UI-Aufruf leitet Omni auf /eula um"
fi

# Nur die Dateien mitschicken, die der Stack wirklich braucht.
for f in ca.pem server-key.pem server-chain.pem omni.asc; do
  cp "${SECRETS_DIR}/${f}" "${STAGE}/secrets/${f}"
done
chmod 600 "${STAGE}/secrets/server-key.pem" "${STAGE}/secrets/omni.asc"
chmod 644 "${STAGE}/secrets/ca.pem" "${STAGE}/secrets/server-chain.pem"
ok "gerendert"

# --- 3. Auf den Host kopieren ---------------------------------------------
log "Uebertrage nach $(host_label):${OMNI_REMOTE_DIR}"
ensure_host_dir "${OMNI_REMOTE_DIR}"
host_sync "${STAGE}/" "${OMNI_REMOTE_DIR}/" --exclude 'sqlite/' 
on_host "mkdir -p '${OMNI_REMOTE_DIR}/sqlite' && chmod 700 '${OMNI_REMOTE_DIR}/secrets'"
ok "kopiert"

# --- 4. Hostnamen auf dem Omni-Host aufloesen ------------------------------
# Die Container loesen die .internal-Namen ueber extra_hosts selbst auf, und die
# Health-Checks unten gehen ueber 127.0.0.1. Der Eintrag ist also nur Komfort,
# falls du vom Host aus per Browser oder curl auf die Namen zugreifst — deshalb
# ist er optional und kein Abbruchgrund.
if on_host "grep -q '${OMNI_ENDPOINT}' /etc/hosts" 2>/dev/null; then
  ok "${OMNI_ENDPOINT} steht bereits in /etc/hosts des Hosts"
elif host_can_root; then
  log "Trage ${OMNI_ENDPOINT} und ${AUTH_ENDPOINT} in /etc/hosts des Hosts ein"
  on_host_root "echo '127.0.0.1 ${OMNI_ENDPOINT} ${AUTH_ENDPOINT}' >> /etc/hosts"
  ok "/etc/hosts gesetzt"
else
  warn "Kein Root auf dem Host — /etc/hosts bleibt unveraendert (nur Komfortverlust)"
fi

# --- 5. Starten ------------------------------------------------------------
detect_host_docker

log "Starte den Stack"
on_host "cd '${OMNI_REMOTE_DIR}' && ${HOST_DOCKER} compose pull --quiet && ${HOST_DOCKER} compose up -d"

log "Container"
on_host "cd '${OMNI_REMOTE_DIR}' && ${HOST_DOCKER} compose ps --format 'table {{.Name}}\t{{.Status}}'" || true

# --- 6. Warten und pruefen -------------------------------------------------
# Bei einem Fehlschlag immer beide Container zeigen. Ein Fehler in dex aeussert
# sich in den omni-Logs nur als "connection refused" und fuehrt in die Irre.
dump_stack_diagnostics() {
  echo
  warn "Container-Status:"
  on_host "cd '${OMNI_REMOTE_DIR}' && ${HOST_DOCKER} compose ps -a --format 'table {{.Name}}\t{{.Status}}'" || true
  for svc in dex omni; do
    echo
    warn "Logs ${svc}:"
    on_host "cd '${OMNI_REMOTE_DIR}' && ${HOST_DOCKER} compose logs --tail=30 ${svc}" || true
  done
}

# --- 6. Warten und pruefen -------------------------------------------------
# Dex zuerst: Omni beendet sich beim Start, wenn dessen OIDC-Discovery nicht
# antwortet. Ein Fehler hier ist also die eigentliche Ursache, nicht die Folge.
dex_up() { on_host "curl -sk -o /dev/null https://127.0.0.1:5556/.well-known/openid-configuration" 2>/dev/null; }
if wait_for 120 "Dex auf Port 5556" dex_up; then
  ok "Dex antwortet"
else
  dump_stack_diagnostics
  die "Dex kam nicht hoch — ohne ihn startet Omni nicht"
fi

omni_up() { on_host "curl -sk -o /dev/null https://127.0.0.1:443" 2>/dev/null; }
if wait_for 180 "Omni auf Port 443" omni_up; then
  ok "Omni antwortet"
else
  dump_stack_diagnostics
  die "Abbruch"
fi

echo
ok "Omni laeuft auf $(host_label)."
dim "Naechster Schritt: scripts/30-client-setup.sh"
