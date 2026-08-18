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

case "$(uname -s)" in
  Darwin)
    if security find-certificate -c "Omni Internal Root CA" /Library/Keychains/System.keychain >/dev/null 2>&1; then
      ok "CA liegt bereits im System-Schluesselbund"
    else
      warn "CA ist noch nicht vertraut. Folgender Befehl wird ausgefuehrt:"
      dim "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ${CA_CRT}"
      read -rp "     Ausfuehren? [j/N] " a
      if [[ "${a}" =~ ^[jJyY]$ ]]; then
        sudo security add-trusted-cert -d -r trustRoot \
          -k /Library/Keychains/System.keychain "${CA_CRT}" \
          && ok "CA im Schluesselbund" \
          || warn "Import fehlgeschlagen — notfalls ca.pem manuell in die Schluesselbundverwaltung ziehen"
      else
        warn "uebersprungen — Browser und omnictl werden dem Zertifikat nicht trauen"
      fi
    fi
    ;;
  Linux)
    if [[ -f /etc/ssl/certs/omni-internal-ca.pem ]]; then
      ok "CA bereits installiert"
    else
      warn "CA installieren mit:"
      dim "sudo cp ${CA_CRT} /usr/local/share/ca-certificates/omni-internal-ca.crt"
      dim "sudo update-ca-certificates"
    fi
    ;;
  *)
    warn "Unbekanntes Betriebssystem — CA ${CA_CRT} manuell als vertrauenswuerdig eintragen"
    ;;
esac

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

# --- 4. Verbindung testen --------------------------------------------------
log "Teste die Verbindung"
dim "Beim ersten Aufruf oeffnet omnictl den Browser zur Anmeldung bei Dex."
dim "Login: ${OMNI_USER_EMAIL} mit dem Passwort aus scripts/10-secrets.sh"
echo
if omni get clusters 2>&1 | head -20; then
  echo
  ok "omnictl spricht mit Omni."
else
  echo
  warn "Verbindung noch nicht moeglich. Haeufige Ursachen:"
  dim "  - EULA noch nicht bestaetigt: https://${OMNI_ENDPOINT}/eula im Browser oeffnen"
  dim "  - CA nicht vertraut (Schritt 2)"
  dim "  - ${OMNI_ENDPOINT} loest nicht auf (Schritt 1)"
fi

echo
dim "UI: https://${OMNI_ENDPOINT}"
dim "Naechster Schritt: scripts/40-infra-provider.sh"
