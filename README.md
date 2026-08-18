# Kubernetes auf Proxmox mit Omni

Provisioniert einen Talos-Linux-Cluster auf Proxmox VE über ein selbst gehostetes
[Omni](https://github.com/siderolabs/omni) und den offiziellen
[Proxmox-Infrastructure-Provider](https://github.com/siderolabs/omni-infra-provider-proxmox).

Schwesterprojekt zu [malagant/capi-proxmox](https://github.com/malagant/capi-proxmox),
das denselben Zweck über Cluster API und kubeadm löst.
Der Vergleich steht unten unter [Verhältnis zum Cluster-API-Repo](#verhältnis-zum-cluster-api-repo).

## Lizenz — bitte zuerst lesen

Omni steht unter der **Business Source License 1.1**, nicht unter einer
Open-Source-Lizenz. Der Additional Use Grant erlaubt kostenlos ausschließlich:

* Evaluierung von Omni selbst, in beliebigem Umfang, solange die Evaluierung wirklich läuft
* **Home-Lab und andere persönliche, nicht-kommerzielle Nutzung**
* Wegwerf-Cluster, an denen nichts hängt, sowie interne Schulung

Sobald eine Umgebung entsteht, auf die deine Entwicklung, dein Betrieb oder dein
Geschäft angewiesen ist, ist es Produktionsnutzung und braucht eine kommerzielle
Lizenz. Sidero zählt dazu ausdrücklich Staging, QA, UAT, dauerhafte Dev-Plattformen,
CI-/Build-Infrastruktur und das Betreiben von Kundenclustern als Dienstleister —
unabhängig davon, wie die Umgebung genannt wird und ob Externe darauf zugreifen.

Dieses Repo ist für den erlaubten Fall gebaut: Home-Lab und Evaluierung. Wenn der
Cluster geschäftlich genutzt wird, ist [Omni SaaS](https://www.siderolabs.com/pricing/)
oder ein Self-hosted-Vertrag mit Sidero der richtige Weg — technisch ändert sich
dabei fast nichts, der Omni-Stack in `stack/` entfällt einfach.

Quelle: [Production vs. Non-Production Use](https://docs.siderolabs.com/omni/self-hosted/production-vs-non-production.md).

## Wie das zusammenspielt

```
  Arbeitsrechner              Omni-Host (Linux)                Proxmox-Cluster
  (oder der Host selbst)      ─────────────────                ───────────────
  omnictl  ──── HTTPS 443 ──▶  Omni                            pve1  pve2  pve3
  Browser  ──── HTTPS 5556 ─▶  Dex (OIDC)                        │
                               Proxmox-Provider ── API ─────────▶│ legt VMs an
                                    ▲                            │
                                    │                            ▼
                               SideroLink                    Talos-VMs
                               WireGuard 50180 UDP ◀──────────── melden sich an
                               SideroLink API 8090 ◀────────────
```

Der Ablauf: Omni erzeugt für jede angeforderte VM ein Talos-Schematic, lässt
**Proxmox selbst** das passende `nocloud`-ISO von `factory.talos.dev` laden, klont
daraus eine VM, und die VM meldet sich über einen WireGuard-Tunnel bei Omni. Erst
danach wird sie einem Cluster zugeteilt. Es gibt kein VM-Template, das du pflegen
musst, und keinen Packer-Lauf.

## Voraussetzungen

* **Ein Linux-Host für Omni.** Omni braucht `--net=host`, `/dev/net/tun` und
  WireGuard — unter Docker Desktop oder OrbStack auf macOS läuft das nicht.
  Eine kleine Debian- oder Ubuntu-VM auf dem Proxmox-Cluster genügt: 2 vCPU,
  4 GB RAM, 40 GB Disk, Docker installiert.
* Der Host muss aus dem VM-Netz erreichbar sein (Ports 443, 8090, 8091, 8100,
  5556 TCP und 50180 UDP).
* **Die Proxmox-Nodes brauchen ausgehenden Internetzugang** zu `factory.talos.dev`.
* Ein Proxmox-Storage mit Content-Typ `iso` für die Talos-Images.
* Werkzeuge: `rsync`, `curl`, `jq`, `openssl`, `gpg`, `docker`, `bash >= 4`
  (im Fernbetrieb zusätzlich `ssh`).

`omnictl` wird nicht vorausgesetzt — die Skripte laden die zur Omni-Version
passende Fassung nach `bin/`.

### Wo die Skripte laufen

Beides geht, gesteuert über `OMNI_SSH` in `config/omni.env`:

| `OMNI_SSH` | Bedeutung |
|---|---|
| leer (Standard) | Die Skripte laufen **auf dem Omni-Host selbst**. Kein SSH, kein rsync über Netz. |
| `user@host` | Die Skripte laufen auf deinem Arbeitsrechner und steuern den Omni-Host per SSH. |

In beiden Fällen muss der ausführende Benutzer nicht root sein, braucht dann
aber Mitgliedschaft in der Gruppe `docker` und passwortloses `sudo`, solange
`OMNI_REMOTE_DIR` außerhalb seines Home liegt (der Standard `/opt/omni` tut das).
Wer ohne `sudo` auskommen will, setzt `OMNI_REMOTE_DIR="/home/<user>/omni"` —
dann bleibt nur der `/etc/hosts`-Eintrag aus, was reiner Komfort ist. Das
Preflight prüft beides und sagt konkret, was fehlt.

Die Skripte selbst **nicht** mit `sudo` starten. Sie rufen `sudo` gezielt dort
auf, wo es nötig ist. Ein kompletter Lauf unter `sudo` legt dagegen root-eigene
Dateien in `out/` und `secrets/` an, die den nächsten Lauf als normaler Benutzer
blockieren. Passiert es doch, räumen die Skripte `out/` beim nächsten Mal selbst
auf und weisen bei `secrets/` auf den `chown` hin.

## Ablauf

```bash
cp config/omni.env.example config/omni.env
$EDITOR config/omni.env

scripts/00-preflight.sh        # Tooling, Omni-Host, Proxmox, Versionen
scripts/10-secrets.sh          # CA, Serverzertifikat, GPG-Key, Passworthash
scripts/20-deploy-omni.sh      # Omni + Dex auf den Host ausrollen
scripts/30-client-setup.sh     # /etc/hosts, CA vertrauen, omniconfig
scripts/40-infra-provider.sh   # Proxmox-Provider registrieren und starten
scripts/50-cluster.sh          # MachineClasses + Cluster erzeugen
```

Jedes Skript ist wiederholbar. `50-cluster.sh` ist zugleich der Weg zum
Skalieren: Zahlen in `config/omni.env` ändern, Skript erneut laufen lassen.

### Was die Schritte tun

**`00-preflight.sh`** prüft read-only, bevor etwas angelegt wird: lokales Tooling,
alle Pflichtvariablen, dass `OMNI_HOST_IP` kein Loopback ist, dass `PROXMOX_URL`
auf `/api2/json` endet, dass der Omni-Host Linux ist, Docker und `/dev/net/tun`
hat und die sechs Ports frei sind, dass die Proxmox-Nodes erreichbar sind, ein
ISO-fähiger Storage existiert, `PVE_STORAGE_SELECTOR` auf einen real vorhandenen
Storage zeigt, die Bridge existiert und die Talos-Version über der Omni-Mindest­version 1.9 liegt.

**`10-secrets.sh`** erzeugt alles Geheime lokal nach `secrets/`: eine Root-CA und
ein Serverzertifikat mit SANs für beide Endpunkte und beide IPs, den GPG-Schlüssel
für Omnis etcd-Verschlüsselung und den bcrypt-Hash des Admin-Passworts. Idempotent,
`--force` erzeugt neu.

**`20-deploy-omni.sh`** rendert `stack/` nach `out/omni-host/`, kopiert es per
rsync auf den Host und startet Omni und Dex per Compose. Wartet und zeigt bei
Fehlern die Container-Logs.

**`30-client-setup.sh`** macht deinen Mac zugriffsfähig: `/etc/hosts`-Eintrag,
CA in den System-Schlüsselbund, `omniconfig.yaml`. Fragt vor jedem sudo nach.

**`40-infra-provider.sh`** legt über `omnictl infraprovider create` den Zugang an,
rendert die Provider-Konfiguration mit den Proxmox-Credentials und startet den
Provider-Container neben Omni.

**`50-cluster.sh`** rendert zwei MachineClasses (Control Plane, Worker), wendet sie
an, validiert das Cluster-Template, synchronisiert es und holt am Ende kubeconfig
und talosconfig.

## Zugangsdaten

Der Login am Omni-UI läuft über Dex:

| | |
|---|---|
| Benutzer | der Wert von `OMNI_USER_EMAIL` aus `config/omni.env` |
| Passwort | das bei `scripts/10-secrets.sh` eingegebene |

Das Passwort liegt nirgends im Klartext. `10-secrets.sh` reicht es direkt an
`htpasswd` weiter und speichert nur den bcrypt-Hash in
`secrets/dex-password.hash`. `secrets/dex-client-secret` ist etwas anderes: das
OAuth2-Client-Secret zwischen Omni und Dex, zum Anmelden unbrauchbar.

**Passwort vergessen?** Nur diese eine Datei löschen und das Skript ohne
`--force` erneut laufen lassen — alle anderen Geheimnisse bleiben unangetastet:

```bash
rm secrets/dex-password.hash
scripts/10-secrets.sh        # fragt nur das Passwort neu ab
scripts/20-deploy-omni.sh    # rollt die neue dex.yaml aus
```

`scripts/10-secrets.sh --force` ist dafür der falsche Weg: es erzeugt auch
`omni.asc` neu, den Schlüssel für Omnis etcd-Verschlüsselung. Ein bestehender
Omni-Bestand wäre danach unlesbar — Cluster, Maschinen, Benutzer und
Service-Accounts inklusive. Das Skript fragt in dem Fall inzwischen nach.

## Entscheidungen, die vom Standard abweichen

**`providerdata` in snake_case.** Das README des Proxmox-Providers zeigt an einer
Stelle `cpu:`, `diskSize:` und `storageSelector:`. Der Provider liest diese Felder
nicht — die Struct-Tags in `internal/pkg/provider/data.go` heißen `cores`,
`disk_size` und `storage_selector`. `templates/machineclass.yaml.tmpl` folgt dem
Code, nicht dem README.

**Zufälliges Dex-Client-Secret.** Die Dokumentation verwendet durchgängig das
feste `omni-dex-secret`. `10-secrets.sh` erzeugt stattdessen 32 zufällige Bytes.

**openssl statt cfssl.** Die Omni-Anleitung installiert cfssl. Für eine CA und ein
Zertifikat reicht openssl, das auf macOS ohnehin da ist — ein Werkzeug weniger.

**Eigener GPG-Keyring.** Der etcd-Schlüssel entsteht in `secrets/gnupg` statt in
`~/.gnupg`, damit dein persönlicher Schlüsselbund unberührt bleibt.

**Service-Account-kubeconfig.** `50-cluster.sh` holt die kubeconfig als
Service-Account-Variante, damit sie mit reinem `kubectl` funktioniert. Die
OIDC-Variante (`omnictl kubeconfig -c <cluster>`) braucht zusätzlich das
`kubectl oidc-login`-Plugin.

## Fallstricke

**`OMNI_HOST_IP` ist die Adresse, die die VMs sehen.** Sie geht als
`--siderolink-wireguard-advertised-addr` in Omni. Steht dort eine Adresse, die aus
dem VM-Netz nicht erreichbar ist, starten die VMs, bleiben aber unsichtbar.

**`PROXMOX_URL` braucht `/api2/json`.** Der Provider erwartet die vollständige
API-URL. [capi-proxmox](https://github.com/malagant/capi-proxmox) will dieselbe URL
**ohne** diesen Pfad —
eine häufige Verwechslung, wenn man beide Repos parallel betreibt.

**Ohne `storage_selector` bricht die Provisionierung ab.** Der Provider meldet den
Fehler erst im Schritt `vmSync`, also nachdem die VM-Anforderung schon läuft. Der
Wert ist ein CEL-Ausdruck, üblicherweise `name == "local-lvm"`.

**Die Proxmox-Nodes brauchen Internet.** Nicht der Provider lädt das Talos-ISO,
sondern Proxmox selbst. Ohne ausgehenden Zugang zu `factory.talos.dev` bleibt die
Provisionierung im Schritt `uploadISO` stehen. Das Preflight kann das nicht prüfen
und weist nur darauf hin.

**Infra-Provider-Key ≠ Service-Account-Key.** `omnictl infraprovider create` und
`omnictl serviceaccount create` liefern beide eine Zeile `OMNI_SERVICE_ACCOUNT_KEY=`.
Der Provider akzeptiert nur den ersten.

**EULA blockiert die API.** Ohne `EULA_NAME`/`EULA_EMAIL` lehnt self-hosted Omni
alle API-Aufrufe ab, bis du im Browser unter `/eula` zustimmst. `omnictl` meldet
das nicht besonders deutlich.

## Diagnose

```bash
export OMNICONFIG=$PWD/omniconfig.yaml
OMNICTL=bin/omnictl-v1.10.3

$OMNICTL get machines
$OMNICTL get machinestatus
$OMNICTL get infraproviderstatus
$OMNICTL get clusterstatus
$OMNICTL cluster template status -f out/cluster/cluster.yaml

# Auf dem Omni-Host
ssh root@omni.lan 'cd /opt/omni          && docker compose logs -f omni'
ssh root@omni.lan 'cd /opt/omni/provider && docker compose logs -f'
```

| Symptom | Ursache |
|---|---|
| VMs entstehen, tauchen in Omni nie auf | `OMNI_HOST_IP` aus dem VM-Netz nicht erreichbar, oder 50180/UDP blockiert |
| Provisionierung hängt bei `uploadISO` | Proxmox-Node erreicht `factory.talos.dev` nicht |
| Provisionierung bricht bei `vmSync` ab | `storage_selector` fehlt oder zeigt ins Leere |
| Provider registriert sich nicht | Service-Account-Key statt Infra-Provider-Key, oder CA nicht gemountet |
| `omnictl` bekommt nur Fehler | EULA nicht bestätigt, CA nicht vertraut, oder `omni.internal` löst nicht auf |
| Browser warnt vor dem Zertifikat | CA nicht im Schlüsselbund — `scripts/30-client-setup.sh` |
| VM-Klon schlägt fehl | `PVE_STORAGE_SELECTOR` zeigt auf einen Storage, den der Zielnode nicht hat |
| `rm: cannot remove .../out/...: Permission denied` | Ein früherer Lauf lief unter `sudo` und hat root-eigene Dateien im Repo hinterlassen |
| `secrets/... ist nicht lesbar` | dito — `sudo chown -R $(id -un) secrets/` |

## Abbau

```bash
scripts/99-teardown.sh          # nur den Cluster, VMs werden in Proxmox entfernt
scripts/99-teardown.sh --all    # zusätzlich Provider und Omni-Stack
```

## Verhältnis zum Cluster-API-Repo

|  | [capi-proxmox](https://github.com/malagant/capi-proxmox) (Cluster API) | dieses Repo (Omni) |
|---|---|---|
| Node-OS | Ubuntu 24.04 | Talos Linux |
| Steuerebene | CAPI-Controller im Cluster | Omni auf eigenem Host |
| VM-Vorlage | selbst gebaut mit image-builder | keine, Omni holt das Image |
| IP-Vergabe | CAPI-IPAM, statisch | Talos via DHCP, Omni via WireGuard |
| Lizenz | Apache 2.0 | Business Source License |
| Betriebsaufwand | Provider-Versionen im Blick behalten | Omni monatlich aktualisieren |
| Passt für | dauerhaften Betrieb, auch geschäftlich | Home-Lab, Evaluierung |

Beide Wege sind vollständig lauffähig und stören einander nicht — sie können
gegen denselben Proxmox-Cluster laufen, solange sich IP-Bereiche und VMIDs nicht
überschneiden.

## Struktur

```
config/omni.env.example        Konfiguration, dokumentiert
stack/docker-compose.yaml.tmpl Omni + Dex
stack/dex.yaml.tmpl            OIDC-Provider
stack/provider-compose.yaml.tmpl  Proxmox-Infra-Provider
templates/machineclass.yaml.tmpl  VM-Form je Rolle
templates/cluster.yaml.tmpl    Cluster-Definition
scripts/lib.sh                 gemeinsame Helfer
scripts/00-preflight.sh        Prüfungen, read-only
scripts/10-secrets.sh          CA, Zertifikat, GPG, Passworthash
scripts/20-deploy-omni.sh      Omni ausrollen
scripts/30-client-setup.sh     lokalen Zugriff einrichten
scripts/40-infra-provider.sh   Proxmox-Provider
scripts/50-cluster.sh          Cluster erzeugen und skalieren
scripts/99-teardown.sh         Abbau
```

`config/omni.env`, `secrets/`, `out/`, `bin/`, `.cache/`, `omniconfig.yaml` und
alle `*.kubeconfig` sind gitignored.
