#!/usr/bin/env bash
# Prueft lokales Tooling, den Omni-Host und den Proxmox-Zugang. Read-only.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

FAILED=0
fail() { printf '%sfail%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; FAILED=1; }

# --- 1. Lokales Tooling ----------------------------------------------------
log "Lokales Tooling"
for c in ssh rsync curl jq openssl gpg; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c"
  else
    fail "$c fehlt"
  fi
done

ensure_omnictl
ok "omnictl ${OMNI_VERSION}  ${OMNICTL}"

# --- 2. Pflichtvariablen ---------------------------------------------------
log "Konfiguration"
require_vars OMNI_SSH OMNI_HOST_IP OMNI_ENDPOINT AUTH_ENDPOINT OMNI_USER_EMAIL \
             OMNI_REMOTE_DIR OMNI_VERSION DEX_VERSION PROXMOX_PROVIDER_VERSION \
             PROXMOX_URL PROXMOX_PROVIDER_ID PVE_STORAGE_SELECTOR \
             PVE_NETWORK_BRIDGE CLUSTER_NAME TALOS_VERSION KUBERNETES_VERSION \
             CONTROL_PLANE_COUNT WORKER_COUNT
ok "alle Pflichtvariablen gesetzt"

if [[ -z "${PROXMOX_TOKEN_SECRET:-}" && -z "${PROXMOX_PASSWORD:-}" ]]; then
  fail "Weder PROXMOX_TOKEN_SECRET noch PROXMOX_PASSWORD gesetzt"
fi

if [[ -z "${EULA_NAME:-}" || -z "${EULA_EMAIL:-}" ]]; then
  warn "EULA_NAME/EULA_EMAIL leer — Omni blockiert dann alle API-Aufrufe, bis du im UI zustimmst"
fi

case "${OMNI_HOST_IP}" in
  127.*|localhost) fail "OMNI_HOST_IP darf nicht loopback sein — die Talos-VMs muessen die Adresse erreichen" ;;
  *) ok "OMNI_HOST_IP ${OMNI_HOST_IP}" ;;
esac

# PROXMOX_URL muss fuer den Provider auf /api2/json enden.
if [[ "${PROXMOX_URL}" == */api2/json ]]; then
  ok "PROXMOX_URL endet auf /api2/json"
else
  fail "PROXMOX_URL muss auf /api2/json enden (der Provider erwartet das): ${PROXMOX_URL}"
fi

# --- 3. Omni-Host ----------------------------------------------------------
log "Omni-Host (${OMNI_SSH})"
if ! host_reachable; then
  fail "SSH zu ${OMNI_SSH} nicht moeglich (BatchMode — Key-Auth noetig)"
else
  ok "SSH erreichbar"

  HOST_OS="$(on_host uname -s 2>/dev/null || echo unknown)"
  if [[ "${HOST_OS}" == "Linux" ]]; then
    ok "Host laeuft Linux"
  else
    fail "Omni-Host meldet '${HOST_OS}' — Omni braucht Linux (--net=host, /dev/net/tun, WireGuard)"
  fi

  if on_host "command -v docker" >/dev/null 2>&1; then
    ok "docker vorhanden: $(on_host 'docker --version' 2>/dev/null)"
  else
    fail "docker auf dem Omni-Host nicht installiert"
  fi

  # Rechte des SSH-Benutzers. OMNI_SSH muss nicht root sein, aber Verzeichnisse
  # unter /opt und der /etc/hosts-Eintrag brauchen erhoehte Rechte.
  detect_host_privileges
  case "${HOST_ROOT_MODE}" in
    direct) ok "SSH-Benutzer ist root" ;;
    sudo)   ok "SSH-Benutzer '${HOST_USER}' hat passwortloses sudo" ;;
    none)   warn "SSH-Benutzer '${HOST_USER}' hat kein passwortloses sudo" ;;
  esac

  # Kann der Benutzer docker ueberhaupt bedienen?
  if on_host 'docker info' >/dev/null 2>&1; then
    ok "docker ohne sudo nutzbar"
  elif [[ "${HOST_ROOT_MODE}" != "none" ]] && on_host 'sudo -n docker info' >/dev/null 2>&1; then
    warn "docker nur mit sudo nutzbar — funktioniert, ist aber unbequem"
    dim  "sudo usermod -aG docker ${HOST_USER}   (danach neu anmelden)"
  else
    fail "docker ist als '${HOST_USER}' nicht nutzbar: sudo usermod -aG docker ${HOST_USER}"
  fi

  # Laesst sich OMNI_REMOTE_DIR ueberhaupt anlegen?
  REMOTE_PARENT="$(dirname "${OMNI_REMOTE_DIR}")"
  if on_host "test -w '${REMOTE_PARENT}'" 2>/dev/null; then
    ok "${REMOTE_PARENT} ist fuer '${HOST_USER}' beschreibbar"
  elif [[ "${HOST_ROOT_MODE}" != "none" ]]; then
    ok "${REMOTE_PARENT} gehoert root — wird per sudo angelegt und uebereignet"
  else
    fail "${OMNI_REMOTE_DIR} kann nicht angelegt werden: '${REMOTE_PARENT}' gehoert root und '${HOST_USER}' hat kein sudo.
     Entweder passwortloses sudo einrichten oder OMNI_REMOTE_DIR ins Home legen,
     z.B. OMNI_REMOTE_DIR=\"/home/${HOST_USER}/omni\""
  fi

  if on_host "test -e /dev/net/tun" 2>/dev/null; then
    ok "/dev/net/tun vorhanden"
  else
    fail "/dev/net/tun fehlt — WireGuard/SideroLink kann nicht starten"
  fi

  # Belegte Ports wuerden den Start still scheitern lassen.
  for p in 443 8090 8091 8100 5556; do
    if on_host "ss -ltn 2>/dev/null | grep -q ':${p} '" 2>/dev/null; then
      fail "Port ${p}/tcp auf dem Omni-Host ist bereits belegt"
    fi
  done
  ok "Ports 443, 8090, 8091, 8100, 5556 frei"

  # Die IP muss auf dem Host tatsaechlich existieren, sonst annonciert
  # SideroLink eine Adresse, unter der die VMs nichts finden.
  if on_host "ip -4 addr show 2>/dev/null | grep -q 'inet ${OMNI_HOST_IP}/'" 2>/dev/null; then
    ok "OMNI_HOST_IP ist auf dem Host konfiguriert"
  else
    warn "OMNI_HOST_IP ${OMNI_HOST_IP} wurde auf dem Host nicht gefunden — pruefen, ob NAT im Spiel ist"
  fi
fi

# --- 4. Proxmox ------------------------------------------------------------
log "Proxmox"
if [[ -z "${PROXMOX_TOKEN_SECRET:-}" ]]; then
  warn "Nur Token-Auth wird hier geprueft — mit Benutzer/Passwort ueberspringe ich die Proxmox-Checks"
elif ! NODES_JSON="$(pve_api GET /nodes 2>/dev/null)"; then
  fail "Proxmox-API ${PROXMOX_URL} nicht erreichbar oder Token ungueltig"
else
  ok "API erreichbar, Token gueltig"
  mapfile -t PVE_NODES < <(echo "${NODES_JSON}" | jq -r '.data[].node')
  dim "Nodes: ${PVE_NODES[*]}"

  FIRST_NODE="${PVE_NODES[0]}"

  if STOR="$(pve_api GET "/nodes/${FIRST_NODE}/storage" 2>/dev/null)"; then
    # Der Provider laedt das Talos-ISO ueber Proxmox auf einen ISO-faehigen Storage.
    ISO_STORES="$(echo "${STOR}" | jq -r '.data[] | select(.content | test("iso")) | .storage' | paste -sd, -)"
    if [[ -n "${ISO_STORES}" ]]; then
      ok "ISO-faehiger Storage vorhanden: ${ISO_STORES}"
    else
      fail "Kein Storage mit content-Typ 'iso' — der Provider kann das Talos-Image nicht ablegen"
    fi

    # storage_selector ist ein CEL-Ausdruck; der uebliche Fall ist name == "x".
    SEL_NAME="$(echo "${PVE_STORAGE_SELECTOR}" | sed -n 's/.*name *== *"\([^"]*\)".*/\1/p')"
    if [[ -n "${SEL_NAME}" ]]; then
      if echo "${STOR}" | jq -e --arg s "${SEL_NAME}" '.data[] | select(.storage == $s)' >/dev/null 2>&1; then
        ok "PVE_STORAGE_SELECTOR trifft vorhandenen Storage '${SEL_NAME}'"
      else
        fail "PVE_STORAGE_SELECTOR verweist auf '${SEL_NAME}', das es auf ${FIRST_NODE} nicht gibt"
      fi
    else
      dim "PVE_STORAGE_SELECTOR ist kein einfacher name==-Ausdruck, ungeprueft"
    fi
  fi

  # Die Bridge muss existieren, sonst haengen die VMs ohne Netz.
  if NETS="$(pve_api GET "/nodes/${FIRST_NODE}/network" 2>/dev/null)"; then
    if echo "${NETS}" | jq -e --arg b "${PVE_NETWORK_BRIDGE}" '.data[] | select(.iface == $b)' >/dev/null 2>&1; then
      ok "Bridge ${PVE_NETWORK_BRIDGE} existiert auf ${FIRST_NODE}"
    else
      fail "Bridge ${PVE_NETWORK_BRIDGE} auf ${FIRST_NODE} nicht gefunden"
    fi
  fi
fi

warn "Ungeprueft: die Proxmox-Nodes muessen factory.talos.dev erreichen."
dim  "Der Provider laesst Proxmox das Talos-ISO selbst herunterladen — ohne"
dim  "ausgehenden Internetzugang der PVE-Nodes bleibt die Provisionierung im"
dim  "Schritt uploadISO stehen."

# --- 5. Talos-Version ------------------------------------------------------
log "Talos-Version"
TALOS_MINOR="$(echo "${TALOS_VERSION}" | sed -n 's/^v1\.\([0-9]*\)\..*/\1/p')"
if [[ -n "${TALOS_MINOR}" ]] && (( TALOS_MINOR >= 9 )); then
  ok "Talos ${TALOS_VERSION} liegt ueber der Omni-Mindestversion 1.9"
else
  fail "Omni unterstuetzt mindestens Talos 1.9, konfiguriert ist ${TALOS_VERSION}"
fi

if curl -fsS -o /dev/null "https://github.com/siderolabs/talos/releases/tag/${TALOS_VERSION}" 2>/dev/null; then
  ok "Talos-Release ${TALOS_VERSION} existiert"
else
  fail "Talos-Release ${TALOS_VERSION} nicht gefunden"
fi

# --- Ergebnis --------------------------------------------------------------
echo
if (( FAILED )); then
  die "Preflight fehlgeschlagen — obige Punkte beheben."
fi
ok "Preflight bestanden. Naechster Schritt: scripts/10-secrets.sh"
