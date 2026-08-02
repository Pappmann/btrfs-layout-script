# btrfs-layout

Tres scripts que convierten un servidor Debian, Ubuntu u otra distribución basada en Debian en un sistema Btrfs bien organizado y listo para instantáneas:

- **`setup-btrfs.sh`** — migra una única partición root en Btrfs a una estructura clara de subvolúmenes, lista para Timeshift y cargas de trabajo con contenedores.
- **`setup-timeshift.sh`** — instala y conecta Timeshift con `grub-btrfs`, incluida la regeneración automática de GRUB después de guardar un comentario desde la GUI.
- **`setup-snapper.sh`** — una vez que root se ejecuta desde un subvolumen con nombre, añade encima una configuración de Snapper al estilo SUSE: instantáneas de línea de tiempo, instantáneas alrededor de cada cambio de `apt` e instantáneas arrancables desde GRUB mediante `grub-btrfs`.

Ejecuta primero `setup-btrfs.sh`; `setup-timeshift.sh` y `setup-snapper.sh` requieren un subvolumen root con nombre y te lo indicarán si aún no es el caso.

## Idiomas

- [English](README.md)
- [Deutsch](README.de.md)
- Español (este archivo)

## setup-btrfs.sh

`setup-btrfs.sh` ayuda a convertir un **servidor Debian, Ubuntu u otra distribución basada en Debian con una única partición root en Btrfs** en un sistema con una estructura clara de subvolúmenes, listo para Timeshift y cargas de trabajo con contenedores. Funciona tanto para el cambio único en una instalación nueva como, después, en un sistema ya en marcha y migrado, para añadir los subvolúmenes que aún falten (sin necesidad de reiniciar).

### Qué hace el script

En un sistema basado en Debian con root en Btrfs, el script:

- Detecta el dispositivo root actual con `findmnt` (por ejemplo `/dev/vda2[/@rootfs]` → `/dev/vda2`).
- Monta el nivel superior de Btrfs (`subvolid=5`) en `/mnt/btrfs-root`.
- Comprueba el espacio libre de antemano (cada byte en `/` se duplica brevemente durante la migración) y aborta si el espacio es insuficiente.
- Detecta una migración ya (parcialmente) realizada y cambia automáticamente a un **modo incremental**: si `/` ya se ejecuta desde un subvolumen con nombre, root, GRUB y el subvolumen por defecto no se tocan — solo se añaden subvolúmenes para las rutas destino que aún no están montadas por separado, activos de inmediato, sin necesidad de reiniciar. Cada ruta destino se clasifica individualmente: ya configurada correctamente (se omite, ni siquiera aparece en el diálogo de selección), ocupada por otra cosa (se omite con una advertencia, nunca se sobrescribe), o aún pendiente (candidata para selección).
- Pide confirmación explícita en una terminal interactiva (escribir "ja") antes de cambiar nada, con una advertencia sobre lo que hace el script y que un fallo puede dejar el sistema sin arrancar. Se omite sin terminal (ejecuciones automatizadas).
- Muestra un diálogo de selección interactivo (`whiptail`) si se ejecuta en una terminal: los subvolúmenes universalmente útiles (`@root`, `@home`, `@log`, `@cache`, `@tmp_var`, `@tmp`) están preseleccionados, todo lo que depende de la pila de software (bases de datos, ClamAV, Docker/Podman, docroot de servidor web) empieza deseleccionado — ambos ajustables libremente. Las rutas deseleccionadas simplemente se quedan en `@` sin subvolumen propio. Sin terminal interactiva (por ejemplo, ejecuciones automatizadas), solo se crean los subvolúmenes universalmente útiles sin preguntar.
- Detiene servicios conocidos de bases de datos, datastores y contenedores antes de copiar sus datos si están activos. En modo incremental se reinician después de activar los nuevos montajes; en la migración inicial quedan detenidos hasta el reinicio — para una copia consistente en lugar de archivos a medio escribir.
- Ofrece opcionalmente una selección interactiva solo con paquetes APT, con descripciones breves, para:
  - `timeshift`: snapshots sencillos de restauración del sistema.
  - `snapper`: gestión de snapshots Btrfs para servidor/CLI.
  - `btrbk`: backups Btrfs y replicación por SSH.
  - `btrfsmaintenance`: tareas programadas de scrub, balance, trim y defrag.
  - `duperemove`: deduplicación de extents Btrfs coincidentes.
  - `grub-btrfs`: hace que los snapshots de Btrfs sean arrancables desde el menú de GRUB — **avanzado**: requiere un gestor de snapshots ya configurado (Timeshift/Snapper). Después, ejecuta `setup-timeshift.sh` o `setup-snapper.sh` para la integración completa.

  Las herramientas solo se instalan — no se configuran automáticamente.
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

- Copia el sistema root actual a `@` (excluyendo `/dev`, `/proc`, `/sys`, `/run`, `/mnt`, `/media`, `/lost+found`, además de — derivado automáticamente del mapeo de abajo — cada ruta que tenga su propio subvolumen).
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

  Los subvolúmenes de bases de datos y datastores (`@mongodb`, `@mysql`, `@postgresql`, `@chroma`, `@clamav`, `@stalwart`, `@elasticsearch`, `@opensearch`, `@clickhouse`, `@cassandra`, `@couchdb`, `@neo4j`, `@rabbitmq`) y los volúmenes nombrados de Docker/Podman (`@docker-volumes`, `@containers-volumes`) conservan montajes Btrfs normales con CoW y checksums, pero reciben `btrfs property set ... compression no` antes de copiar los datos. Así el script no depende de opciones `compress`/`nodatacow` en fstab por subvolumen, que Btrfs no separa de forma fiable entre montajes del mismo sistema de archivos. Las capas de imagen y metadatos en `@docker`/`@containers` siguen usando la política comprimida normal.

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
- Valida el nuevo `/etc/fstab` automáticamente con `findmnt --verify` (solo lectura, no remonta nada en caliente) y aborta antes de que reinicies por error con un fstab roto.

Resultado:

- Root se ejecuta desde `@` (compatible con Timeshift).
- Rutas importantes como `/home`, `/var/log`, `/var/lib/docker`, `/var/www` viven en subvolúmenes separados.

### Requisitos

- Sistema Debian o basado en Debian con:
  - `apt`
  - `systemd`
- Sistema de ficheros root en **Btrfs** sobre un único dispositivo (por ejemplo una partición Btrfs `/dev/vda2`); no activar **LVM** para el sistema de ficheros root.
- Ejecutar el script como **root**.

El script instalará automáticamente, si faltan:

- `rsync`
- `btrfs-progs`

En una ejecución interactiva, el script también puede ofrecer paquetes APT opcionales (`timeshift`, `snapper`, `btrbk`, `btrfsmaintenance`, `duperemove`) si están disponibles en los repositorios configurados. En ejecuciones automatizadas/no interactivas esta selección se omite.

> Lo más sencillo es usarlo en una **instalación nueva de servidor**, ya que ahí todos los directorios están vacíos o son pequeños. Pero el script también funciona en sistemas ya en producción, **siempre que haya suficiente espacio libre** (se comprueba automáticamente — cada byte en `/` se duplica brevemente durante la migración). Para una copia consistente, los servicios conocidos de bases de datos, datastores y contenedores se detienen automáticamente antes de copiar sus datos; en modo incremental se reinician después de `mount -a` y en la migración inicial quedan detenidos hasta el reinicio.
>
> Aun así, en un sistema en producción: haz una copia de seguridad antes, planifica una ventana de mantenimiento para el reinicio final, y ten en cuenta que las aplicaciones **fuera** de esta lista (por ejemplo un proceso de servidor web propio con archivos abiertos en `/srv` o `/var/www`) siguen funcionando durante la copia y en teoría podrían acabar con una instantánea inconsistente en su subvolumen.

### Uso

1. Instala Debian de forma que tengas:

   - una pequeña partición EFI (por ejemplo `/dev/vda1`),
   - una partición grande en Btrfs como root (por ejemplo `/dev/vda2`).
   - LVM no seleccionado/activado para el sistema de ficheros root.

2. Inicia sesión como root (o usa `sudo`).

3. Clona este repositorio:

   ```bash
   git clone https://github.com/debian-btrfs/layout-script.git
   cd btrfs-layout
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

## setup-timeshift.sh

`setup-timeshift.sh` conecta una configuración Btrfs existente de Timeshift con `grub-btrfs`. No adivina ni sobrescribe el dispositivo de backup ni los horarios de snapshots configurados.

### Qué hace el script

- Comprueba que `/` se ejecute desde un subvolumen Btrfs con nombre y que Timeshift esté configurado en modo Btrfs con un dispositivo de backup.
- Crea una instantánea guardia read-only antes de modificar el sistema.
- Instala `timeshift` e `inotify-tools` cuando sea necesario y reutiliza una instalación manual completa de `grub-btrfs` si el paquete no está disponible mediante APT.
- Corrige el comportamiento conocido del analizador de `grub-btrfs` que elimina las comas de los comentarios de Timeshift; el generador original se guarda en `/var/lib/btrfs-layout/`.
- Activa `grub-btrfsd` si el paquete proporciona la unidad y genera la configuración inicial de GRUB.
- Instala `timeshift-grub-btrfs-sync.service`. El watcher detecta snapshots nuevos/eliminados y escrituras o renombrados de `info.json`; por eso un comentario guardado después de crear un snapshot en la GUI también actualiza GRUB.
- Es idempotente y no reinicia el equipo automáticamente.

### Requisitos

- Sistema Debian o basado en Debian con `apt` y `systemd`.
- Sistema de archivos root ya en un subvolumen Btrfs **con nombre**.
- Timeshift configurado previamente en modo Btrfs con un dispositivo de backup seleccionado.
- Ejecutar el script como **root**.

### Uso

```bash
chmod +x setup-timeshift.sh
sudo ./setup-timeshift.sh
```

Para una ejecución automatizada sin terminal:

```bash
sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-timeshift.sh
```

Verifica la integración con:

```bash
systemctl status grub-btrfsd timeshift-grub-btrfs-sync.service
grub-script-check /boot/grub/grub.cfg
grep -n 'Description' /boot/grub/grub-btrfs.cfg
```

Crea un snapshot con `timeshift --create --comments "after update"`, o créalo desde la GUI y guarda después un comentario. El watcher regenera el menú de snapshots de GRUB tras el cambio de metadatos. GRUB arranca los snapshots en modo solo lectura; esto no implementa un rollback automático del sistema.

## setup-snapper.sh

`setup-snapper.sh` convierte un servidor Debian, Ubuntu u otro basado en Debian cuyo sistema de archivos raíz ya se ejecuta desde un subvolumen Btrfs con nombre (por ejemplo mediante `setup-btrfs.sh` arriba) en una configuración de Snapper al estilo SUSE: instantáneas de línea de tiempo automáticas, instantáneas alrededor de cada cambio de paquete `apt` e instantáneas arrancables directamente desde el menú de GRUB mediante `grub-btrfs`.

### Qué hace el script

En un sistema Debian (o basado en Debian) cuyo `/` ya está en un subvolumen Btrfs con nombre, el script:

- Verifica que `/` sea Btrfs y se ejecute desde un subvolumen con nombre (p. ej. `@`); si no, aborta indicando que se ejecute antes `setup-btrfs.sh`.
- Crea antes del primer cambio una instantánea Btrfs read-only del subvolumen raíz actual (p. ej. `@.before-snapper-setup-...`) como punto de recuperación manual si la configuración falla.
- Instala `snapper` e `inotify-tools` (necesario para que `grub-btrfsd` detecte nuevas instantáneas) si faltan.
- Pide confirmación explícita en una terminal interactiva (escribiendo "ja") antes de cambiar nada. Sin terminal, el script aborta salvo que `LAYOUT_SCRIPT_ASSUME_YES=1` esté definido.
- Crea la configuración `root` de Snapper (idempotente — se omite si ya existe), lo que crea `.snapshots` como subvolumen Btrfs anidado.
- Añade `.snapshots` como entrada propia en `/etc/fstab` y lo monta. La `fstab` anterior se guarda antes y se restaura automáticamente si falla `findmnt --verify` o `mount -a`.
- Establece una política de línea de tiempo al estilo SUSE en `/etc/snapper/configs/root` (`TIMELINE_CREATE`, `TIMELINE_CLEANUP`, `NUMBER_CLEANUP` y valores conservadores de `TIMELINE_LIMIT_*` para hora/día/semana/mes/año).
- Instala hooks propios de `apt` (`DPkg::Pre-Invoke`/`DPkg::Post-Invoke`) que crean un par de instantáneas pre/post en cada cambio de paquete — a diferencia del plugin `zypp` de openSUSE, Debian/Ubuntu no incluye esta integración, así que el script escribe pequeños scripts auxiliares para ello.
- Activa los temporizadores systemd `snapper-timeline.timer` y `snapper-cleanup.timer`.
- Instala `grub-btrfs` si está disponible en los repositorios APT configurados, configura `grub-btrfsd` para vigilar el directorio `/.snapshots` de Snapper y ejecuta `update-grub` (o `grub-mkconfig`) para que las instantáneas aparezcan como entradas arrancables de solo lectura en el menú de GRUB. Timeshift no es necesario para este recorrido. Si el paquete no está disponible, la configuración de Snapper continúa sin integración en el menú de GRUB.

### Limitaciones

Examinar instantáneas, comparar archivos individuales y arrancar en modo solo lectura una instantánea desde el menú de GRUB (`grub-btrfs`) funcionan con esta configuración si `grub-btrfs` está disponible. La instantánea de guardia es read-only a propósito y sirve como punto de recuperación manual: arrancar un sistema de rescate, montar el top-level de Btrfs, crear desde ella una nueva instantánea raíz escribible y ajustar de nuevo bootloader/fstab. Una **reversión completa del sistema** arrancable como la que hace `snapper rollback` en openSUSE requiere además que root se ejecute desde dentro de un subvolumen `.snapshots/<N>/snapshot`; esto no ocurre automáticamente con un diseño `@` simple.

### Requisitos

- Sistema Debian o basado en Debian con `apt` y `systemd`.
- Sistema de archivos raíz ya en un subvolumen Btrfs **con nombre** (si no, ejecutar antes `setup-btrfs.sh` arriba).
- Ejecutar el script como **root**.

El script instalará los siguientes paquetes si faltan: `snapper`, `inotify-tools`, opcionalmente `grub-btrfs`.

### Uso

1. Asegurarse de que `/` ya se ejecuta desde un subvolumen Btrfs con nombre (ver `setup-btrfs.sh` arriba).

2. Hacer el script ejecutable y ejecutarlo:

   ```bash
   chmod +x setup-snapper.sh
   sudo ./setup-snapper.sh
   ```

   Para ejecuciones automatizadas sin terminal:

   ```bash
   sudo LAYOUT_SCRIPT_ASSUME_YES=1 ./setup-snapper.sh
   ```

3. Verificar:

   ```bash
   snapper list-configs
   snapper create -d test && snapper list && snapper delete <número>
   systemctl status snapper-timeline.timer snapper-cleanup.timer grub-btrfsd
   systemctl cat grub-btrfsd.service
   ```

   En una configuración solo con Snapper, el `ExecStart` efectivo debe contener `grub-btrfsd --syslog /.snapshots` y no debe contener `--timeshift-auto`. `setup-snapper.sh` y `setup-timeshift.sh` gestionan el mismo drop-in; ejecuta el script correspondiente al gestor de snapshots elegido.

   Instalar/eliminar un paquete pequeño para confirmar que los hooks de `apt` crean un par de instantáneas pre/post, y reiniciar para confirmar que el menú de GRUB muestra un submenú de instantáneas.

## Licencia

Este proyecto está licenciado bajo la **GNU General Public License v3.0 o posterior (GPL-3.0-or-later)**.

Ver el archivo `LICENSE` para más detalles.
