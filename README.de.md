# btrfs-layout

Drei Skripte, die aus einem Debian-, Ubuntu- oder anderen Debian-basierten Server ein gut organisiertes, snapshot-fähiges Btrfs-System machen:

- **`setup-btrfs.sh`** — migriert eine einzelne Btrfs-Root-Partition in eine saubere Subvolume-Struktur, geeignet für Timeshift und Container-Workloads.
- **`setup-timeshift.sh`** — installiert und verbindet Timeshift mit `grub-btrfs`, einschließlich automatischer GRUB-Aktualisierung nach dem Speichern eines GUI-Kommentars.
- **`setup-snapper.sh`** — sobald Root von einem benannten Subvolume läuft, ergänzt das ein SUSE-artiges Snapper-Setup: Timeline-Snapshots, Snapshots rund um jede `apt`-Änderung und über GRUB bootbare Snapshots via `grub-btrfs`.

Zuerst `setup-btrfs.sh` ausführen; `setup-timeshift.sh` und `setup-snapper.sh` setzen ein benanntes Root-Subvolume voraus und weisen darauf hin, falls das noch nicht der Fall ist.

## Sprachen

- [English](README.md)
- Deutsch (diese Datei)
- [Español](README.es.md)

## setup-btrfs.sh

`setup-btrfs.sh` hilft dabei, einen **Debian-, Ubuntu- oder anderen Debian-basierten Server mit einer einzelnen Btrfs-Root-Partition** in ein System mit sauberer Subvolume-Struktur zu verwandeln – geeignet für Timeshift und Container-Workloads. Funktioniert sowohl beim einmaligen Umstieg auf einer frischen Installation als auch nachträglich auf einem bereits laufenden, migrierten System, um dort noch fehlende Subvolumes zu ergänzen (kein Neustart nötig).

### Was das Skript macht

Auf einem Debian- (oder Debian-basierten) System mit Btrfs-Root führt das Skript im Wesentlichen aus:

- Ermittelt das aktuelle Root-Device per `findmnt` (z. B. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mountet das Btrfs-Top-Level (`subvolid=5`) nach `/mnt/btrfs-root`.
- Prüft vorab den freien Speicherplatz (jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert) und bricht ab, wenn es eng wird.
- Erkennt eine schon (teilweise) durchgeführte Migration und wechselt automatisch in einen **inkrementellen Modus**: Läuft `/` bereits von einem benannten Subvolume, werden Root, GRUB und das Default-Subvolume nicht mehr angefasst — es werden nur noch fehlende Subvolumes für noch nicht separat gemountete Pfade ergänzt, sofort aktiv, ohne Neustart. Jeder Zielpfad wird einzeln klassifiziert: bereits korrekt eingerichtet (übersprungen, taucht im Auswahldialog gar nicht erst auf), anderweitig belegt (übersprungen mit Warnung, wird nicht überschrieben), oder noch offen (Kandidat für die Auswahl).
- Fragt in einem interaktiven Terminal ausdrücklich nach ("ja" eintippen), bevor irgendetwas verändert wird — samt Warnhinweis, was das Skript tut und dass ein Fehlschlag das System unbootbar machen kann. Ohne Terminal (automatisierte Läufe) wird die Abfrage übersprungen.
- Zeigt in einem interaktiven Terminal einen Auswahldialog (`whiptail`): universell sinnvolle Subvolumes (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) sind vorausgewählt, alle vom Software-Stack abhängigen (Datenbanken, ClamAV, Docker/Podman, Webserver-Docroot) starten abgewählt — beides frei änderbar. Abgewählte Pfade bekommen kein eigenes Subvolume und bleiben einfach Teil von `@`. Ohne interaktives Terminal (z.B. bei automatisierter Ausführung) werden nur die universell sinnvollen Subvolumes ohne Nachfrage angelegt.
- Stoppt bekannte Datenbank-, Datastore- und Container-Dienste vor deren Datenkopie, falls sie gerade laufen. Im inkrementellen Modus werden sie nach aktiven neuen Mounts neu gestartet; im initialen Migrationsmodus bleiben sie bis zum Reboot gestoppt — für eine konsistente Kopie statt halbgeschriebener Dateien.
- Bietet optional eine interaktive APT-Auswahl mit Kurzbeschreibungen für:
  - `timeshift`: einfache System-Restore-Snapshots.
  - `snapper`: Server-/CLI-Snapshotverwaltung für Btrfs.
  - `btrbk`: Btrfs-Backups und Replikation per SSH.
  - `btrfsmaintenance`: geplante Scrub-, Balance-, Trim- und Defrag-Aufgaben.
  - `duperemove`: Deduplizierung gleicher Btrfs-Extents.
  - `grub-btrfs`: Btrfs-Snapshots im GRUB-Bootmenü bootbar machen — **fortgeschritten**: setzt einen bereits eingerichteten Snapshot-Manager (Timeshift/Snapper) voraus. Für die vollständige Integration danach `setup-timeshift.sh` oder `setup-snapper.sh` ausführen.

  Die Tools werden nur installiert — nicht automatisch konfiguriert.
- Legt (idempotent) folgende Subvolumes an:

  - `@` (neues Root)
  - `@root`
  - `@home`
  - `@spool`
  - `@log`
  - `@cache`
  - `@tmp_var`
  - `@srv`
  - `@tmp`
  - `@opt`
  - `@containers`
  - `@docker`
  - `@mongodb`
  - `@mysql`
  - `@postgresql`
  - `@chroma`
  - `@clamav`
  - `@stalwart`
  - `@elasticsearch`
  - `@opensearch`
  - `@clickhouse`
  - `@cassandra`
  - `@couchdb`
  - `@neo4j`
  - `@rabbitmq`
  - `@docker-volumes`
  - `@containers-volumes`
  - `@www`

- Kopiert das aktuelle Root-Dateisystem nach `@` (mit Ausschlüssen für `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found` sowie – automatisch aus dem Mapping unten abgeleitet – allen Pfaden, die ein eigenes Subvolume bekommen).
- Kopiert die Inhalte wichtiger Verzeichnisse in ihre Subvolumes:

  - `/root` → `@root`
  - `/home` → `@home`
  - `/var/spool` → `@spool`
  - `/var/log` → `@log`
  - `/var/cache` → `@cache`
  - `/var/tmp` → `@tmp_var`
  - `/srv` → `@srv`
  - `/tmp` → `@tmp`
  - `/opt` → `@opt`
  - `/var/lib/containers` → `@containers`
  - `/var/lib/docker` → `@docker`
  - `/var/lib/mongodb` → `@mongodb`
  - `/var/lib/mysql` → `@mysql`
  - `/var/lib/postgresql` → `@postgresql`
  - `/var/lib/chroma` → `@chroma`
  - `/var/lib/clamav` → `@clamav`
  - `/var/lib/stalwart` → `@stalwart`
  - `/var/lib/elasticsearch` → `@elasticsearch`
  - `/var/lib/opensearch` → `@opensearch`
  - `/var/lib/clickhouse` → `@clickhouse`
  - `/var/lib/cassandra` → `@cassandra`
  - `/var/lib/couchdb` → `@couchdb`
  - `/var/lib/neo4j` → `@neo4j`
  - `/var/lib/rabbitmq` → `@rabbitmq`
  - `/var/lib/docker/volumes` → `@docker-volumes`
  - `/var/lib/containers/storage/volumes` → `@containers-volumes`
  - `/var/www` → `@www`

  Datenbank- und Datastore-Subvolumes (`@mongodb`, `@mysql`, `@postgresql`, `@chroma`, `@clamav`, `@stalwart`, `@elasticsearch`, `@opensearch`, `@clickhouse`, `@cassandra`, `@couchdb`, `@neo4j`, `@rabbitmq`) sowie die benannten Docker-/Podman-Volumes (`@docker-volumes`, `@containers-volumes`) behalten normale Btrfs-Mounts mit CoW und Prüfsummen, bekommen aber vor der Datenkopie `btrfs property set ... compression no`. Damit verlässt sich das Skript nicht auf per-Subvolume gesetzte `compress`-/`nodatacow`-fstab-Optionen, die Btrfs für Mounts desselben Dateisystems nicht zuverlässig getrennt unterstützt. Image-Layer und Metadaten in `@docker`/`@containers` selbst bleiben auf der normalen komprimierten Policy.

- Bereitet im neuen Root (`@`) die Mountpoints vor, damit die Subvolumes dort eingehängt werden können.
- Passt `/etc/fstab` im laufenden System an:

  - legt ein Backup als `fstab.backup-YYYY-MM-DD-HHMMSS` an,
  - kommentiert alte Btrfs-Root-Zeilen als `#OLD-ROOT …` aus,
  - fügt neue Btrfs-Einträge für `/`, `/home`, `/var/log`, `/var/lib/docker`, `/var/www` usw. mit den entsprechenden `@…`-Subvolumes hinzu.

- Passt GRUB an (falls vorhanden):

  - ersetzt ggf. `@rootfs` durch `@` in `/etc/default/grub`,
  - ruft `update-grub` oder `grub-mkconfig -o /boot/grub/grub.cfg` auf (sofern vorhanden).

- Setzt das Btrfs-Default-Subvolume auf `@`, sodass das System von `@` bootet.
- Stellt sicher, dass die benötigten Mountpoints auch im aktuellen Root existieren (`/home`, `/var/lib/docker`, …).
- Validiert die neue `/etc/fstab` automatisch mit `findmnt --verify` (rein lesend, mountet nichts live um) und bricht bei Problemen ab, bevor du versehentlich mit einer kaputten fstab neu startest.

Das Ergebnis:

- Root läuft von `@` (Timeshift-kompatibel).
- Wichtige Pfade wie `/home`, `/var/log`, `/var/lib/docker`, `/var/www` liegen auf eigenen Subvolumes.

### Voraussetzungen

- Debian oder Debian-basiertes System mit:
  - `apt`
  - `systemd`
- Root-Dateisystem ist **Btrfs** auf einem einzelnen Device (z. B. eine Btrfs-Partition `/dev/vda2`); **LVM nicht** für das Root-Dateisystem aktivieren.
- Das Skript wird als **root** ausgeführt.

Bei Bedarf installiert das Skript automatisch:

- `rsync`
- `btrfs-progs`

In einem interaktiven Lauf kann das Skript außerdem optionale APT-Pakete (`timeshift`, `snapper`, `btrbk`, `btrfsmaintenance`, `duperemove`) anbieten, sofern sie in den konfigurierten Paketquellen verfügbar sind. In automatisierten/nicht interaktiven Läufen wird diese Auswahl übersprungen.

> Am unkompliziertesten auf einer **frischen Server-Installation**, da dort alle Verzeichnisse klein/leer sind. Das Skript funktioniert aber auch auf bereits laufenden Systemen, **sofern genug freier Speicherplatz vorhanden ist** (wird automatisch geprüft – jedes Byte auf `/` wird während der Migration kurzzeitig dupliziert). Für eine konsistente Kopie werden bekannte Datenbank-, Datastore- und Container-Dienste vor ihrer jeweiligen Datenkopie automatisch gestoppt; im inkrementellen Modus nach `mount -a` neu gestartet und im initialen Migrationsmodus bis zum Reboot gestoppt gelassen.
>
> Trotzdem gilt auf laufenden Systemen: mach vorher ein Backup, plane ein Wartungsfenster für den abschließenden Neustart ein, und bedenke, dass Anwendungen **außerhalb** dieser Liste (z. B. ein eigener Webserver-Prozess mit offenen Dateien in `/srv` oder `/var/www`) während der Kopie weiterlaufen und dadurch theoretisch eine inkonsistente Momentaufnahme in ihr Subvolume bekommen könnten.

### Verwendung

1. Debian so installieren, dass du erhältst:

   - eine kleine EFI-Partition (z. B. `/dev/vda1`)
   - eine große Btrfs-Partition als Root (z. B. `/dev/vda2`)
   - LVM für das Root-Dateisystem nicht ausgewählt/aktiviert ist

2. Als root anmelden (oder `sudo` verwenden).

3. Repository klonen:

   ```bash
   git clone https://github.com/debian-btrfs/layout-script.git
   cd btrfs-layout
   ```

4. Skript ausführbar machen:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Skript ausführen:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. `/etc/fstab` prüfen und sicherstellen, dass:

   - `/` mit `subvol=@` eingetragen ist,
   - die zusätzlichen Pfade (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) passende Einträge mit den erwarteten `@…`-Subvolumes haben.

7. Mounts anwenden und testen:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   Es sollten keine Fehler erscheinen.

8. Neustart:

   ```bash
   reboot
   ```

9. Nach dem Neustart prüfen:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   Erwartung:

   - `/` von `...[/@]` mit `subvol=@`
   - `/home` von `...[/@home]` usw.

Damit ist das Layout für Timeshift und Container-Workloads vorbereitet.

## setup-timeshift.sh

`setup-timeshift.sh` verbindet eine vorhandene Timeshift-Btrfs-Konfiguration mit `grub-btrfs`. Das Skript errät oder überschreibt weder das konfigurierte Backup-Gerät noch die Snapshot-Zeitpläne.

### Was das Skript tut

- Prüft, dass `/` von einem benannten Btrfs-Subvolume läuft und Timeshift im Btrfs-Modus mit ausgewähltem Backup-Gerät konfiguriert ist.
- Erstellt vor Änderungen einen read-only Guard-Snapshot.
- Installiert bei Bedarf `timeshift` und `inotify-tools` und verwendet eine vollständige manuelle `grub-btrfs`-Installation weiter, wenn das Paket über APT nicht verfügbar ist.
- Korrigiert das bekannte `grub-btrfs`-Parserverhalten, das Kommas aus Timeshift-Kommentaren entfernt; der ursprüngliche Generator wird unter `/var/lib/btrfs-layout/` gesichert.
- Aktiviert `grub-btrfsd`, sofern das Paket die Unit bereitstellt, und erzeugt die initiale GRUB-Konfiguration.
- Installiert `timeshift-grub-btrfs-sync.service`. Der Watcher erkennt neue und gelöschte Snapshots sowie Schreib- und Umbenennungsereignisse an `info.json`. Dadurch löst auch ein nachträglich in der Timeshift-GUI gespeicherter Kommentar eine GRUB-Aktualisierung aus.
- Ist idempotent und startet den Rechner nicht automatisch neu.

### Voraussetzungen

- Debian oder Debian-basiertes System mit `apt` und `systemd`.
- Root-Dateisystem bereits auf einem **benannten** Btrfs-Subvolume.
- Timeshift bereits im Btrfs-Modus mit ausgewähltem Backup-Gerät konfiguriert.
- Das Skript als **root** ausführen.

### Verwendung

```bash
chmod +x setup-timeshift.sh
sudo ./setup-timeshift.sh
```

Für einen automatisierten Lauf ohne Terminal:

```bash
sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-timeshift.sh
```

Integration prüfen:

```bash
systemctl status grub-btrfsd timeshift-grub-btrfs-sync.service
grub-script-check /boot/grub/grub.cfg
grep -n 'Description' /boot/grub/grub-btrfs.cfg
```

Einen Snapshot mit `timeshift --create --comments "after update"` oder über die GUI erstellen und danach einen Kommentar speichern. Der Watcher erzeugt die GRUB-Snapshot-Konfiguration nach der Metadatenänderung neu. GRUB startet Snapshots read-only; dieses Setup ist kein automatischer System-Rollback.

## setup-snapper.sh

`setup-snapper.sh` macht aus einem Debian-, Ubuntu- oder anderen Debian-basierten Server, dessen Root-Dateisystem bereits von einem benannten Btrfs-Subvolume läuft (z.B. via `setup-btrfs.sh` oben), ein SUSE-artiges Snapper-Setup: automatische Timeline-Snapshots, Snapshots rund um jede `apt`-Paketänderung und Snapshots, die direkt aus dem GRUB-Menü über `grub-btrfs` bootbar sind.

### Was das Skript tut

Auf einem Debian(-basierten) System, dessen `/` bereits auf einem benannten Btrfs-Subvolume liegt, macht das Skript Folgendes:

- Prüft, dass `/` Btrfs ist und von einem benannten Subvolume läuft (z.B. `@`); bricht mit Hinweis auf `setup-btrfs.sh` ab, falls nicht.
- Erstellt vor der ersten Änderung einen read-only Btrfs-Guard-Snapshot des aktuellen Root-Subvolumes (z.B. `@.before-snapper-setup-...`) als manuellen Rücksetzpunkt, falls während der Einrichtung etwas schiefgeht.
- Installiert `snapper` und `inotify-tools` (von `grub-btrfsd` benötigt, um neue Snapshots zu erkennen), falls nicht vorhanden.
- Fragt in einem interaktiven Terminal ausdrücklich nach Bestätigung (Eingabe von "ja"), bevor irgendetwas verändert wird. Ohne Terminal bricht das Skript ab, außer `LAYOUT_SCRIPT_ASSUME_YES=1` ist gesetzt.
- Legt die Snapper-Konfiguration `root` an (idempotent — wird übersprungen, falls schon vorhanden); dabei entsteht `.snapshots` als nested Btrfs-Subvolume.
- Trägt `.snapshots` als eigenen Eintrag in `/etc/fstab` ein und mountet es. Die alte `fstab` wird vorher gesichert und bei `findmnt --verify`- oder `mount -a`-Fehlern automatisch zurückgespielt.
- Setzt eine SUSE-artige Timeline-Policy in `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP` sowie konservative `TIMELINE_LIMIT_*`-Werte für stündlich/täglich/wöchentlich/monatlich/jährlich).
- Installiert eigene `apt`-Hooks (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`), die rund um jede Paketänderung ein Pre-/Post-Snapshot-Paar anlegen — Debian/Ubuntu liefert diese Integration anders als das `zypp`-Plugin von openSUSE nicht mit, weshalb das Skript dafür kleine Wrapper-Skripte schreibt.
- Aktiviert die systemd-Timer `snapper-timeline.timer` und `snapper-cleanup.timer`.
- Installiert `grub-btrfs`, falls das Paket in den konfigurierten APT-Quellen verfügbar ist, konfiguriert `grub-btrfsd` für die Überwachung von Snapper-`/.snapshots` und führt `update-grub` (bzw. `grub-mkconfig`) aus, damit Snapshots als bootbare, read-only-Einträge im GRUB-Menü erscheinen. Timeshift ist für diesen Pfad nicht erforderlich. Ist das Paket nicht verfügbar, läuft die Snapper-Einrichtung ohne GRUB-Menü-Integration weiter.

### Grenzen

Snapshot-Browsing, das Diffen einzelner Dateien und ein read-only-Boot eines Snapshots über das GRUB-Menü (`grub-btrfs`) funktionieren mit diesem Setup, sofern `grub-btrfs` verfügbar ist. Der Guard-Snapshot ist bewusst read-only und dient als manueller Rücksetzpunkt: Für eine Wiederherstellung von einem Rettungssystem booten, das Btrfs-Top-Level mounten, aus dem Guard-Snapshot einen neuen schreibbaren Root-Snapshot erzeugen und Bootloader/fstab passend zurückstellen. Ein vollständiger bootbarer **System-Rollback**, wie ihn `snapper rollback` unter openSUSE macht, setzt zusätzlich voraus, dass Root aus einem `.snapshots/<N>/snapshot`-Subvolume läuft — das ist bei einem einfachen `@`-Layout nicht automatisch der Fall und müsste bei Bedarf manuell nachgezogen werden.

### Voraussetzungen

- Debian oder Debian-basiertes System mit `apt` und `systemd`.
- Root-Dateisystem bereits auf einem **benannten** Btrfs-Subvolume (falls nicht, zuerst `setup-btrfs.sh` oben ausführen).
- Das Skript als **root** ausführen.

Das Skript installiert bei Bedarf folgende Pakete: `snapper`, `inotify-tools`, optional `grub-btrfs`.

### Verwendung

1. Sicherstellen, dass `/` bereits von einem benannten Btrfs-Subvolume läuft (siehe `setup-btrfs.sh` oben).

2. Skript ausführbar machen und starten:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

   Für automatisierte Läufe ohne Terminal:

   ```bash
   sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-snapper.sh
   ```

3. Prüfen:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <Nummer>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   systemctl cat grub-btrfsd.service
   ```

   Bei einer reinen Snapper-Einrichtung muss der wirksame `ExecStart` `grub-btrfsd --syslog /.snapshots` enthalten und darf nicht `--timeshift-auto` enthalten. `setup-snapper.sh` und `setup-timeshift.sh` verwalten dasselbe Drop-in; das Skript für den ausgewählten Snapshot-Manager ausführen.

   Ein kleines Paket installieren/entfernen, um zu prüfen, dass die `apt`-Hooks ein Pre-/Post-Snapshot-Paar erzeugen, und neu starten, um zu prüfen, dass das GRUB-Menü ein Snapshot-Untermenü zeigt.

## Lizenz

Dieses Projekt steht unter der **GNU General Public License v3.0 oder später (GPL-3.0-or-later)**.

Details siehe Datei `LICENSE`.
