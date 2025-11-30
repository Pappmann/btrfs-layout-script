# btrfs-layout-script

`setup-btrfs.sh` ayuda a convertir un **servidor Debian recién instalado con una única partición root en Btrfs** en un sistema con una estructura clara de subvolúmenes, listo para Timeshift y cargas de trabajo con contenedores.

## Idiomas

- [English](README.md)
- [Deutsch](README.de.md)
- Español (este archivo)

## Qué hace el script

En un sistema basado en Debian con root en Btrfs, el script:

- Detecta el dispositivo root actual con `findmnt` (por ejemplo `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Monta el nivel superior de Btrfs (`subvolid=5`) en `/mnt/btrfs-root`.
- Crea (de forma idempotente) los siguientes subvolúmenes:

  - `@` (nuevo root)
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

- Copia el sistema root actual a `@` (excluyendo `/dev`, `/proc`, `/sys`, `/run`, `/tmp`, `/mnt`, `/media`, …).
- Copia el contenido de los directorios principales a sus subvolúmenes:

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

- Prepara los puntos de montaje dentro del nuevo root (`@`) para que los subvolúmenes se puedan montar allí.
- Modifica `/etc/fstab` en el sistema actual:

  - crea una copia de seguridad `fstab.backup-YYYY-MM-DD-HHMMSS`,
  - comenta las líneas antiguas de root Btrfs como `#OLD-ROOT …`,
  - añade nuevas entradas Btrfs para `/`, `/home`, `/var/log`, `/var/lib/docker`, `/var/www`, etc., usando los subvolúmenes `@…` correspondientes.

- Ajusta GRUB (si está presente):

  - reemplaza `@rootfs` por `@` en `/etc/default/grub` si es necesario,
  - ejecuta `update-grub` o `grub-mkconfig -o /boot/grub/grub.cfg` si están disponibles.

- Define el subvolumen por defecto de Btrfs como `@`, de modo que el sistema arranque desde `@`.
- Asegura que los puntos de montaje necesarios también existan en el root actual (`/home`, `/var/lib/docker`, …).

Resultado:

- Root se ejecuta desde `@` (compatible con Timeshift).
- Rutas importantes como `/home`, `/var/log`, `/var/lib/docker`, `/var/www` viven en subvolúmenes separados.

## Requisitos

- Sistema Debian o basado en Debian con:
  - `apt`
  - `systemd`
- Sistema de ficheros root en **Btrfs** sobre un único dispositivo (por ejemplo una partición Btrfs `/dev/vda2`).
- Ejecutar el script como **root**.

El script instalará automáticamente, si faltan:

- `rsync`
- `btrfs-progs`

> Uso recomendado: en una **instalación nueva de servidor**, donde reorganizar el sistema de ficheros es aceptable. En sistemas ya muy usados, toma precauciones adicionales y asegúrate de tener copias de seguridad.

## Uso

1. Instala Debian de forma que tengas:

   - una pequeña partición EFI (por ejemplo `/dev/vda1`),
   - una partición grande en Btrfs como root (por ejemplo `/dev/vda2`).

2. Inicia sesión como root (o usa `sudo`).

3. Clona este repositorio:

   ```bash
   git clone https://github.com/<tu-usuario>/btrfs-layout-script.git
   cd btrfs-layout-script
   ```

4. Haz el script ejecutable:

   ```bash
   chmod +x setup-btrfs.sh
   ```

5. Ejecútalo:

   ```bash
   sudo ./setup-btrfs.sh
   ```

6. Revisa `/etc/fstab` y comprueba que:

   - `/` usa `subvol=@`,
   - las rutas adicionales (`/home`, `/var/log`, `/var/lib/docker`, `/var/www`, …) tienen entradas Btrfs con los subvolúmenes `@…` esperados.

7. Aplica y prueba los montajes:

   ```bash
   systemctl daemon-reload
   mount -a
   ```

   No debería mostrar errores.

8. Reinicia:

   ```bash
   reboot
   ```

9. Después del reinicio, verifica:

   ```bash
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /
   findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS /home /var/log /var/lib/docker /var/www
   ```

   Deberías ver:

   - `/` desde `...[/@]` con `subvol=@`,
   - `/home` desde `...[/@home]`, etc.

En este punto, Timeshift puede usar `@` como subvolumen root y tu diseño está listo para snapshots y contenedores.

## Licencia

Este proyecto está licenciado bajo la **GNU General Public License versión 3 o posterior (GPL-3.0-or-later)**.

Consulta el archivo `LICENSE` para más detalles.
