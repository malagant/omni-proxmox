#!/usr/bin/env bash
# Richtet den lokalen Rechner fuer den Zugriff auf Omni ein:
#   - Hostnamen in /etc/hosts
#   - CA ins System-Trust-Store (sonst meckern Browser und omnictl)
#   - omniconfig.yaml fuer omnictl
#
# Die beiden ersten Schritte brauchen sudo und fragen vorher nach.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
require_vars OMNI_HOST_IP OMNI_ENDPOINT AUTH_ENDPOINT OMNI_USER_EMAIL

ensure_omnictl

CA_CRT="${SECRETS_DIR}/ca.pem"
[[ -s "${CA_CRT}" ]] || die "secrets/ca.pem fehlt — erst scripts/10-secrets.sh ausfuehren"

# --- 1. /etc/hosts ---------------------------------------------------------
log "Namensaufloesung"
if grep -qE "^[^#]*\s${OMNI_ENDPOINT}(\s|$)" /etc/hosts 2>/dev/null; then
  ok "${OMNI_ENDPOINT} steht bereits in /etc/hosts"
  dim "$(grep -E "\s${OMNI_ENDPOINT}(\s|$)" /etc/hosts | head -1)"
else
  warn "Eintrag fehlt. Folgende Zeile wird mit sudo angehaengt:"
  dim "${OMNI_HOST_IP}  ${OMNI_ENDPOINT} ${AUTH_ENDPOINT}"
  read -rp "     Eintragen? [j/N] " a
  if [[ "${a}" =~ ^[jJyY]$ ]]; then
    echo "${OMNI_HOST_IP}  ${OMNI_ENDPOINT} ${AUTH_ENDPOINT}" | sudo tee -a /etc/hosts >/dev/null
    ok "eingetragen"
  else
    warn "uebersprungen — ohne Aufloesung funktionieren UI und omnictl nicht"
  fi
fi

# --- 2. CA vertrauen -------------------------------------------------------
log "CA-Vertrauen"
CA_FINGERPRINT="$(openssl x509 -in "${CA_CRT}" -noout -fingerprint -sha256 | cut -d= -f2)"
dim "SHA256 ${CA_FINGERPRINT}"

# Der ehrlichste Test ist die echte TLS-Verifikation gegen Omni, unabhaengig
# davon, wo das jeweilige System seinen Trust-Store hat.
ca_trusted()   { curl -sS -o /dev/null --max-time 5 "https://${OMNI_ENDPOINT}/" >/dev/null 2>&1; }
omni_reachable() { curl -sSk -o /dev/null --max-time 5 "https://${OMNI_ENDPOINT}/" >/dev/null 2>&1; }

# Legt die CA in den passenden Trust-Store. Die Pfade unterscheiden sich je
# Distribution, deshalb Erkennung ueber vorhandene Verzeichnisse statt ueber
# /etc/os-release.
install_ca_linux() {
  local dest cmd
  if command -v update-ca-trust >/dev/null 2>&1 && [[ -d /etc/pki/ca-trust/source/anchors ]]; then
    dest=/etc/pki/ca-trust/source/anchors/omni-internal-ca.crt; cmd=update-ca-trust   # RHEL, Fedora
  elif command -v update-ca-trust >/dev/null 2>&1 && [[ -d /etc/ca-certificates/trust-source/anchors ]]; then
    dest=/etc/ca-certificates/trust-source/anchors/omni-internal-ca.crt; cmd=update-ca-trust   # Arch
  elif command -v update-ca-certificates >/dev/null 2>&1 && [[ -d /usr/local/share/ca-certificates ]]; then
    dest=/usr/local/share/ca-certificates/omni-internal-ca.crt; cmd=update-ca-certificates     # Debian, Ubuntu
  else
    return 1
  fi

  warn "CA ist noch nicht vertraut. Folgende Befehle werden mit sudo ausgefuehrt:"
  dim "sudo cp ${CA_CRT} ${dest}"
  dim "sudo ${cmd}"
  read -rp "     Ausfuehren? [j/N] " a
  [[ "${a}" =~ ^[jJyY]$ ]] || { warn "uebersprungen"; return 2; }

  sudo cp "${CA_CRT}" "${dest}" && sudo "${cmd}"
}

if ! omni_reachable; then
  warn "https://${OMNI_ENDPOINT} ist nicht erreichbar — laeuft der Stack? (scripts/20-deploy-omni.sh)"
elif ca_trusted; then
  ok "CA wird bereits akzeptiert"
else
  case "$(uname -s)" in
    Darwin)
      warn "CA ist noch nicht vertraut. Folgender Befehl wird ausgefuehrt:"
      dim "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_CRT}"
      read -rp "     Ausfuehren? [j/N] " a
      if [[ "${a}" =~ ^[jJyY]$ ]]; then
        sudo security add-trusted-cert -d -r trustRoot \
          -k /Library/Keychains/System.keychain "${CA_CRT}" \
          || warn "Import fehlgeschlagen — ca.pem notfalls manuell in die Schluesselbundverwaltung ziehen"
      else
        warn "uebersprungen"
      fi
      ;;
    Linux)
      CA_RC=0
      install_ca_linux || CA_RC=$?
      case "${CA_RC}" in
        0) : ;;                                     # installiert
        2) : ;;                                     # vom Benutzer uebersprungen
        *) warn "Kein bekannter Trust-Store gefunden. ${CA_CRT} von Hand eintragen." ;;
      esac
      ;;
    *)
      warn "Unbekanntes Betriebssystem — ${CA_CRT} manuell als vertrauenswuerdig eintragen"
      ;;
  esac

  # Gegenprobe: hat es gewirkt?
  if ca_trusted; then
    ok "CA wird jetzt akzeptiert"
  else
    warn "TLS-Verifikation gegen https://${OMNI_ENDPOINT} schlaegt weiterhin fehl."
    dim  "omnictl kann sich ohne vertrauenswuerdige CA nicht anmelden."
  fi
fi

# --- 3. omniconfig ---------------------------------------------------------
log "omnictl-Konfiguration"
OMNICONFIG_FILE="${REPO_ROOT}/omniconfig.yaml"
cat > "${OMNICONFIG_FILE}" <<EOF
# Generiert von scripts/30-client-setup.sh
context: default
contexts:
  default:
    url: https://${OMNI_ENDPOINT}
    auth:
      siderov1:
        identity: ${OMNI_USER_EMAIL}
EOF
ok "${OMNICONFIG_FILE}"
dim "Alle Skripte hier setzen OMNICONFIG automatisch auf diese Datei."
dim "Fuer omnictl von Hand:  export OMNICONFIG=${OMNICONFIG_FILE}"

# --- 4. Anmelden -----------------------------------------------------------
log "Anmeldung"
dim "Beim ersten Aufruf hat omnictl noch keinen Schluessel und meldet:"
dim "  \"Could not authenticate: open ~/.talos/keys/...pgp: no such file\""
dim "Das ist ein Hinweis, kein Fehler. omnictl oeffnet daraufhin den Browser"
dim "und wartet, bis du den Schluessel dort freigibst."
dim "Login: ${OMNI_USER_EMAIL} mit dem Passwort aus scripts/10-secrets.sh"
echo

# Ausgabe bewusst NICHT umleiten oder durch eine Pipe schicken: omnictl startet
# den Browser-Flow nur, wenn stdout ein Terminal ist. Mit Pipe bricht es
# stattdessen mit einem irrefuehrenden "Error: ...pgp: no such file" ab.
if omni get clusters; then
  echo
  ok "omnictl spricht mit Omni."
else
  echo
  warn "Verbindung noch nicht moeglich. Haeufige Ursachen:"
  dim "  - Schluessel im Browser noch nicht freigegeben (obige URL oeffnen)"
  dim "  - EULA noch nicht bestaetigt: https://${OMNI_ENDPOINT}/eula"
  dim "  - CA nicht vertraut (Schritt 2)"
  dim "  - ${OMNI_ENDPOINT} loest nicht auf (Schritt 1)"
  dim "  - ohne Terminal gestartet: omnictl kann den Browser-Flow dann nicht fuehren"
fi

echo
dim "UI: https://${OMNI_ENDPOINT}"
dim "Naechster Schritt: scripts/40-infra-provider.sh"
