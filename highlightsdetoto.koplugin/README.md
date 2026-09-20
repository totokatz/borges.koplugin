# Borges para KOReader

Plugin de sincronización durable entre Kobo/KOReader y tu cuenta de Borges.

Sincroniza:

- progreso, sesiones y estadísticas;
- highlights, notas y marcadores con identidad estable;
- cambios offline mediante outbox/ACK/cursor;
- descargas de la biblioteca EPUB canónica;
- actualizaciones verificadas con rollback.

## Instalación

1. Verificá el SHA-256 del ZIP publicado.
2. Extraé `highlightsdetoto.koplugin` dentro de `.adds/koreader/plugins/`.
3. Reiniciá KOReader.
4. Abrí `Herramientas → Borges → Cuenta`.
5. Escribí tu usuario (o email) y contraseña: los mismos de la web.

El paquete es genérico y ya apunta al servidor oficial. El lector cambia la contraseña por una
credencial propia, la verifica y descarta la contraseña: no se guarda en ningún lado y no vuelve a
pedirse tras un reinicio.

No copies `web_config.json`, `dropbox_config.json`, tokens ni la clave maestra al paquete. Esos
archivos son locales y el actualizador nunca los reemplaza.

## El menú

```text
Borges
├── Cuenta              entrar, ver quién sos, cerrar sesión
├── Sincronizar ahora   la acción: un toque hace todo lo que haya para hacer
├── Biblioteca          bajar libros; seguir donde dejaste en otro dispositivo
├── Estado y ayuda      qué pasó, y los datos para pedir ayuda
└── Avanzado            nombre del lector, servidor, cola, actualizador
```

Cuando hay una versión nueva aparece además `Instalar la versión X`, y se va apenas se instala.

## Idioma

Borges habla el idioma de la interfaz de KOReader. Si KOReader está en castellano
(cualquier variante: `es`, `es_AR`, `es_ES`…) el plugin aparece en castellano; en
**cualquier otro idioma** aparece entero en inglés, incluido el caso en que nunca
elegiste idioma en KOReader. No hay una tercera opción ni un ajuste propio del
plugin: cambiás el idioma en `Herramientas → Más herramientas → Idioma` de KOReader
y Borges cambia con él, sin reiniciar.

Para quien toca el código: los textos del código están en inglés y son la clave;
el castellano vive en `l10n/es.lua` y `i18n.lua` elige. `npm run test:koreader-plugin`
falla si un texto del código no tiene su castellano o si aparece castellano en el
código.

## Uso normal

Al abrir, reanudar o reconectar un libro, Borges consulta dónde fue la última
lectura entre todos tus dispositivos. Si fue en este lector, no pregunta. Si
fue en otro, pregunta aunque esa posición esté más atrás o coincida con la local.
«Ir a esa posición» y «Seguir aquí» guardan tu elección como una nueva lectura
en este dispositivo antes de enviarla.

Hasta consultar y, si corresponde, elegir, el progreso queda guardado y pendiente:
ni una sincronización manual, ni cerrar, suspender o reiniciar pueden enviarlo
primero y ocultar la lectura del otro aparato. Sin conexión podés seguir leyendo;
Borges conserva la hora de esa lectura para cuando vuelva la red. Una elección
guardada se conserva aunque se corte la conexión antes de recibir la confirmación.
Las notas y estadísticas pueden enviarse mientras el progreso espera.

La consulta para retomar la última lectura se hace al abrir, reanudar o recuperar
Wi-Fi incluso con `Sincronizar sola` apagado. Ese ajuste gobierna los otros
automatismos; no puede suprimir la elección de dónde seguir leyendo.

En Kobo y Kindle usamos directamente la conexión con redes guardadas al abrir o retomar un libro.
Desde 2026.09.18.10, al iniciar con una cuenta configurada desactivamos una sola vez la restauración
automática de KOReader, que podía agotar su espera antes de iniciar esa conexión. Respetamos la
preferencia de activar, preguntar o ignorar la conexión. Podés cancelar y seguir leyendo.

Podés volver a activar la restauración automática en los ajustes de red de KOReader: Borges no
sobrescribe esa elección posterior. Si ya había una restauración en curso al cargar la actualización,
la deja terminar y conserva la recuperación de un único intento si falla. Fuera del flujo de Borges,
KOReader deja de restaurar automáticamente Wi-Fi mientras ese ajuste esté desactivado.

`Sincronizar ahora` es una sola operación que guarda lo de hoy, revisa los libros que cambiaron,
manda lo que había quedado de antes e intercambia todo con el servidor. Sin Wi-Fi igual guarda: los
cambios quedan persistidos y no se descartan por cantidad de reintentos. El botón queda apagado
mientras corre, así que un segundo toque no arranca una segunda sincronización.

El texto final dice cuántos cambios se enviaron y se recibieron y cuántos quedaron pendientes. Una
falla nunca se muestra como "Todo al día".

`Biblioteca → Descargar libros de mi biblioteca` trae la edición EPUB canónica. Usar la misma
edición en todos los lectores es lo que habilita posiciones y anotaciones exactas.

`Biblioteca → Seguir donde dejaste en otro dispositivo` siempre pregunta antes de mover el libro, y
el "sí" guarda primero por dónde ibas: después del salto queda `Volver a la pág. N`. Decir que no
deja todo exactamente como estaba.

## Cuenta

`Cuenta` muestra `Sign in`, `Connected as <usuario> ✓` o `Session expired — sign in again`. Sólo el
servidor marca una sesión como vencida: el reloj del lector nunca desconecta por su cuenta, y estar
sin Wi-Fi tampoco.

`Cerrar sesión en este lector` corta la sesión sin red y deja los libros descargados en el
dispositivo. Entrar con otra cuenta no migra la cola ni el cursor —son de la cuenta anterior—; si
hay trabajo sin subir, el plugin ofrece guardar una copia en JSON antes de descartarlo.

## Recuperación

- El aviso de versión nueva vive en el menú de siempre; `Avanzado → Buscar actualizaciones ahora`
  es el chequeo manual.
- Las actualizaciones se instalan como overlays con tamaño y SHA-256 obligatorios.
- Todo Lua descargado se compila antes de tocar el plugin.
- Una instalación interrumpida se restaura automáticamente al siguiente arranque.
- `Avanzado → Volver a la versión …` recupera la anterior y pide reiniciar KOReader.
- `Avanzado → Guardar una copia de lo pendiente` escribe en JSON lo que todavía no se envió, antes
  de cualquier decisión destructiva.

La guía operativa completa está en
[`docs/koreader-plugin-v2.md`](../docs/koreader-plugin-v2.md).
