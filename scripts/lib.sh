#!/usr/bin/env bash
# Gemeinsame Helfer. Wird per `source` eingebunden.

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "Dieses Skript braucht bash >= 4 (gefunden: ${BASH_VERSION}). Auf macOS: brew install bash" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config/omni.env"
BIN_DIR="${REPO_ROOT}/bin"
CACHE_DIR="${REPO_ROOT}/.cache"
SECRETS_DIR="${REPO_ROOT}/secrets"
OUT_DIR="${REPO_ROOT}/out"

mkdir -p "${BIN_DIR}" "${CACHE_DIR}"

# --- Ausgabe ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "${C_BLU}" "${C_OFF}" "$*"; }
ok()   { printf '%s  ok%s %s\n' "${C_GRN}" "${C_OFF}" "$*"; }
warn() { printf '%swarn%s %s\n' "${C_YEL}" "${C_OFF}" "$*" >&2; }
die()  { printf '%sfail%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; exit 1; }
dim()  { printf '%s     %s%s\n' "${C_DIM}" "$*" "${C_OFF}"; }

# --- Konfiguration ---------------------------------------------------------
load_config() {
  [[ -f "${CONFIG_FILE}" ]] || die "config/omni.env fehlt. Anlegen mit:
     cp config/omni.env.example config/omni.env"
  # shellcheck disable=SC1090
  set -a; source "${CONFIG_FILE}"; set +a
}

require_vars() {
  local missing=()
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  (( ${#missing[@]} == 0 )) || die "Nicht gesetzt in config/omni.env: ${missing[*]}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Kommando nicht gefunden: $1${2:+  ($2)}"
}

# --- omnictl ---------------------------------------------------------------
# Gepinnt passend zur Omni-Version, damit CLI und Server nicht auseinanderlaufen.
OMNICTL=""

ensure_omnictl() {
  require_vars OMNI_VERSION
  local target="${BIN_DIR}/omnictl-${OMNI_VERSION}"
  if [[ ! -x "${target}" ]]; then
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    case "$(uname -m)" in
      arm64|aarch64) arch="arm64" ;;
      x86_64|amd64)  arch="amd64" ;;
      *) die "Nicht unterstuetzte Architektur: $(uname -m)" ;;
    esac
    log "Lade omnictl ${OMNI_VERSION} (${os}/${arch}) nach bin/"
    curl -fsSL -o "${target}" \
      "https://github.com/siderolabs/omni/releases/download/${OMNI_VERSION}/omnictl-${os}-${arch}" \
      || die "Download von omnictl ${OMNI_VERSION} fehlgeschlagen"
    chmod +x "${target}"
  fi
  OMNICTL="${target}"
  export OMNICTL
  # omnictl liest die Konfiguration aus OMNICONFIG, sonst ~/.talos/omni/config.
  export OMNICONFIG="${OMNICONFIG:-${REPO_ROOT}/omniconfig.yaml}"
}

# omnictl mit der Repo-Konfiguration aufrufen.
omni() {
  ensure_omnictl
  "${OMNICTL}" "$@"
}

# --- Omni-Host -------------------------------------------------------------
# Kommando auf dem Omni-Host ausfuehren.
on_host() {
  require_vars OMNI_SSH
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${OMNI_SSH}" "$@"
}

host_reachable() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "${OMNI_SSH}" true 2>/dev/null
}

# --- Rechte auf dem Omni-Host ---------------------------------------------
# OMNI_SSH muss nicht root sein. Verzeichnisse unter /opt und der
# /etc/hosts-Eintrag brauchen aber Rechte, die ein normaler Benutzer nicht hat.
HOST_USER=""
HOST_ROOT_MODE=""    # direct | sudo | none

detect_host_privileges() {
  if [[ -n "${HOST_ROOT_MODE}" ]]; then return 0; fi

  HOST_USER="$(on_host 'id -un' 2>/dev/null || true)"
  [[ -n "${HOST_USER}" ]] || die "Konnte den Benutzer auf ${OMNI_SSH} nicht ermitteln"

  if [[ "${HOST_USER}" == "root" ]]; then
    HOST_ROOT_MODE="direct"
  elif on_host 'sudo -n true' >/dev/null 2>&1; then
    HOST_ROOT_MODE="sudo"
  else
    HOST_ROOT_MODE="none"
  fi
}

host_can_root() {
  detect_host_privileges
  [[ "${HOST_ROOT_MODE}" != "none" ]]
}

# Ein Kommando mit Root-Rechten auf dem Host ausfuehren.
on_host_root() {
  local cmd="$1"
  detect_host_privileges
  case "${HOST_ROOT_MODE}" in
    direct) on_host "${cmd}" ;;
    sudo)   on_host "sudo -n bash -c $(printf '%q' "${cmd}")" ;;
    none)
      die "Fuer '${cmd}' werden Root-Rechte auf ${OMNI_SSH} gebraucht.
     Benutzer '${HOST_USER}' hat kein passwortloses sudo. Zwei Wege:
       a) sudo ohne Passwort erlauben:
            echo '${HOST_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/${HOST_USER}
       b) OMNI_REMOTE_DIR in config/omni.env auf einen Pfad im Home setzen,
          z.B. OMNI_REMOTE_DIR=\"/home/${HOST_USER}/omni\""
      ;;
  esac
}

# Legt ein Verzeichnis auf dem Host an und uebereignet es dem SSH-Benutzer.
# Erst ohne Rechteerhoehung versuchen — bei /opt & Co. dann mit.
ensure_host_dir() {
  local dir="$1"
  if on_host "mkdir -p '${dir}'" >/dev/null 2>&1; then
    return 0
  fi
  detect_host_privileges
  log "${dir} braucht Root-Rechte — lege es an und uebereigne es ${HOST_USER}"
  on_host_root "mkdir -p '${dir}'"
  local grp
  grp="$(on_host 'id -gn' 2>/dev/null || echo "${HOST_USER}")"
  on_host_root "chown ${HOST_USER}:${grp} '${dir}'"
}

# --- docker auf dem Host ---------------------------------------------------
# Ohne Mitgliedschaft in der docker-Gruppe braucht der Aufruf sudo.
HOST_DOCKER=""

detect_host_docker() {
  if [[ -n "${HOST_DOCKER}" ]]; then return 0; fi

  if on_host 'docker info' >/dev/null 2>&1; then
    HOST_DOCKER="docker"
  elif host_can_root && on_host 'sudo -n docker info' >/dev/null 2>&1; then
    HOST_DOCKER="sudo -n docker"
    warn "docker laeuft auf dem Host nur mit sudo."
    dim  "Angenehmer waere:  sudo usermod -aG docker ${HOST_USER}  (danach neu anmelden)"
  else
    detect_host_privileges
    die "docker ist auf ${OMNI_SSH} als '${HOST_USER}' nicht nutzbar.
     Benutzer der docker-Gruppe hinzufuegen und neu anmelden:
       sudo usermod -aG docker ${HOST_USER}"
  fi
}

# --- Proxmox ---------------------------------------------------------------
# PROXMOX_URL enthaelt hier bereits /api2/json (so will es der Provider).
pve_api() {
  local method="$1" path="$2"
  local auth
  if [[ -n "${PROXMOX_TOKEN_SECRET:-}" ]]; then
    auth="PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"
  else
    return 1   # Passwort-Auth wird hier nicht unterstuetzt, nur Token.
  fi
  curl -fsSL -k -X "${method}" -H "Authorization: ${auth}" \
    "${PROXMOX_URL%/}${path}"
}

# --- Templates -------------------------------------------------------------
# Ersetzt ${VAR} aus der Umgebung. envsubst ist auf macOS nicht ueberall da,
# deshalb ueber python3.
render_template() {
  local src="$1" dst="$2"
  python3 -c '
import os, sys, re
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
missing = []
def sub(m):
    name = m.group(1)
    val = os.environ.get(name)
    if val is None:
        missing.append(name)
        return m.group(0)
    return val
out = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", sub, text)
if missing:
    sys.exit("Nicht gesetzte Variablen im Template %s: %s" % (src, ", ".join(sorted(set(missing)))))
open(dst, "w").write(out)
' "${src}" "${dst}"
}

# --- Warten ----------------------------------------------------------------
wait_for() {
  local timeout="$1" desc="$2"; shift 2
  local start elapsed
  start="$(date +%s)"
  printf '%s==>%s Warte auf %s ' "${C_BLU}" "${C_OFF}" "${desc}"
  while true; do
    if "$@" >/dev/null 2>&1; then
      printf ' %sok%s\n' "${C_GRN}" "${C_OFF}"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed > timeout )); then
      printf ' %stimeout nach %ss%s\n' "${C_RED}" "${elapsed}" "${C_OFF}"
      return 1
    fi
    printf '.'
    sleep 5
  done
}
