# Borges para KOReader · Borges for KOReader

[Castellano](#castellano) · [English](#english)

---

## Castellano

Plugin de KOReader que conecta tu lector (Kobo, Kindle con KOReader, PocketBook,
Android…) con tu cuenta de [Borges](https://highlights.runadev.com): progreso,
sesiones, estadísticas, subrayados, notas y marcadores, con cola durable para
trabajar sin conexión y actualizaciones verificadas con vuelta atrás.

### Instalar

**Bajá el paquete de la [última release](../../releases/latest)**, no el ZIP del
código fuente que arma GitHub: el instalable se llama
`highlightsdetoto.koplugin-<versión>.zip` y viene con su `.sha256` al lado.

1. Verificá el SHA-256 del ZIP contra el `.sha256` publicado.
2. Descomprimilo: adentro hay una sola carpeta, `highlightsdetoto.koplugin`.
3. Copiá esa carpeta dentro de `koreader/plugins/` del lector
   (en Kobo: `.adds/koreader/plugins/`). Tiene que quedar
   `koreader/plugins/highlightsdetoto.koplugin/main.lua`.
4. Reiniciá KOReader y abrí **Herramientas → Borges → Cuenta**. Entrá con el
   mismo usuario y contraseña de la web.

La guía paso a paso, con capturas, está en
[highlights.runadev.com/guia](https://highlights.runadev.com/guia/).

> La carpeta se llama `highlightsdetoto.koplugin` por compatibilidad: es la
> identidad interna del plugin y la usan las rutas de instalación, el
> actualizador y las copias de respaldo. El nombre visible es «Borges».

### Actualizar

El plugin se actualiza solo desde el lector (**Borges → Estado y ayuda →
Buscar actualizaciones**): baja el paquete, verifica tamaño y SHA-256, instala
con bitácora y conserva la versión anterior para volver atrás. También podés
reemplazar la carpeta a mano con el ZIP de una release.

### Reportar un problema

Desde el propio lector: **Borges → Estado y ayuda → Reportar un problema**
muestra la dirección y el código de soporte de ese aparato. Los issues de este
repositorio son para parches, preguntas sobre el código y compatibilidad con
versiones de KOReader.

### Este repositorio

Contiene sólo el plugin. El servidor y la aplicación web de Borges no están
acá. Cada release se publica con GitHub Actions al crear un tag `v<versión>`;
el ZIP y el `.sha256` que quedan en la release son los que la app enlaza.

---

## English

A KOReader plugin that connects your reader (Kobo, Kindle running KOReader,
PocketBook, Android…) to your [Borges](https://highlights.runadev.com)
account: progress, sessions, statistics, highlights, notes and bookmarks, with
a durable offline queue and verified updates with rollback.

### Install

**Download the package from the [latest release](../../releases/latest)**, not
the source ZIP GitHub generates: the installable file is named
`highlightsdetoto.koplugin-<version>.zip` and ships with its `.sha256`.

1. Check the ZIP's SHA-256 against the published `.sha256`.
2. Unzip it: inside there is a single folder, `highlightsdetoto.koplugin`.
3. Copy that folder into your reader's `koreader/plugins/`
   (on Kobo: `.adds/koreader/plugins/`). You should end up with
   `koreader/plugins/highlightsdetoto.koplugin/main.lua`.
4. Restart KOReader and open **Tools → Borges → Account**. Sign in with the
   same username and password you use on the web.

The step-by-step guide, with screenshots, lives at
[highlights.runadev.com/guia](https://highlights.runadev.com/guia/?lang=en).

> The folder is called `highlightsdetoto.koplugin` for compatibility: it is the
> plugin's internal identity, used by install paths, the updater and backups.
> The visible name is “Borges”.

### Update

The plugin updates itself from the reader (**Borges → Status & help → Check
for updates**): it downloads the package, verifies size and SHA-256, installs
with a journal and keeps the previous version for rollback. You can also
replace the folder by hand with a release ZIP.

### Report a problem

From the reader itself: **Borges → Status & help → Report a problem** shows
the address and the support code for that device. Issues in this repository
are for patches, questions about the code and KOReader version compatibility.

### This repository

Contains only the plugin. The Borges server and web app are not here. Every
release is published by GitHub Actions when a `v<version>` tag is pushed; the
ZIP and `.sha256` attached to the release are what the app links to.
