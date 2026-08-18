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
