# btrfs-layout-script

`setup-btrfs.sh` hilft dabei, einen **frisch installierten Debian-Server mit einer einzelnen Btrfs-Root-Partition** in ein System mit sauberer Subvolume-Struktur zu verwandeln – geeignet für Timeshift und Container-Workloads.

## Sprachen

- [English](README.md)
- Deutsch (diese Datei)
- [Español](README.es.md)

## Was das Skript macht

Auf einem Debian- (oder Debian-basierten) System mit Btrfs-Root führt das Skript im Wesentlichen aus:

- Ermittelt das aktuelle Root-Device per `findmnt` (z. B. `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Mountet das Btrfs-Top-Level (`subvolid=5`) nach `/mnt/btrfs-root`.
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
  - `@www`

- Kopiert das aktuelle Root-Dateisystem nach `@` (mit typischen Ausschlüssen wie `/dev`, `/proc`, `/sys`, `/run`, `/tmp`, `/mnt`, `/media`, …).
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
  - `/var/www` → `@www`

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

Das Ergebnis:

- Root läuft von `@` (Timeshift-kompatibel).
- Wichtige Pfade wie `/home`, `/var/log`, `/var/lib/docker`, `/var/www` liegen auf eigenen Subvolumes.

## Voraussetzungen

- Debian oder Debian-basiertes System mit:
  - `apt`
  - `systemd`
- Root-Dateisystem ist **Btrfs** auf einem einzelnen Device (z. B. eine Btrfs-Partition `/dev/vda2`).
- Das Skript wird als **root** ausgeführt.

Bei Bedarf installiert das Skript automatisch:

- `rsync`
- `btrfs-progs`

> Empfohlener Einsatz: auf einer **frischen Server-Installation**, bei der die Neu-Strukturierung des Dateisystems in Ordnung ist. Auf bereits stark genutzten Systemen solltest du besonders sorgfältig testen und ein Backup haben.

## Verwendung

1. Debian so installieren, dass du erhältst:

   - eine kleine EFI-Partition (z. B. `/dev/vda1`)
   - eine große Btrfs-Partition als Root (z. B. `/dev/vda2`)

2. Als root anmelden (oder `sudo` verwenden).

3. Repository klonen:

   ```bash
   git clone https://github.com/<dein-user>/btrfs-layout-script.git
   cd btrfs-layout-script
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

## Lizenz

Dieses Projekt steht unter der **GNU General Public License Version 3 oder neuer (GPL-3.0-or-later)**.

Details findest du in der Datei `LICENSE`.
