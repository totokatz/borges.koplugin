# Novedades de Borges para KOReader

Cada sección es una versión publicada. El servidor lee de acá el texto que el
lector ve en «Ver novedades» antes de instalar, así que las notas viajan
dentro del paquete y quedan cubiertas por el mismo SHA-256 que el resto de la
release. Una versión sin sección se ofrece igual, sin novedades para mostrar.

Escribí en criollo y en presente, una línea por cambio, pensando en alguien
que está por tocar «Actualizar» en un lector de tinta electrónica.

## 2026.09.20.4

- The installation folder is now borges.koplugin. Close KOReader and rename the existing plugin folder before copying this package over it. Keep your configuration files and only one installed copy.
- The plugin appears as Borges and preserves existing account settings and offline synchronization data.

## 2026.09.20.3

- Borges tiene dirección nueva: borges.runadev.com. Si tu lector ya estaba
  configurado, no tenés que cambiar nada: la dirección anterior sigue
  respondiendo para los lectores que la tienen guardada.
- Un lector recién instalado apunta solo a la dirección nueva.

## 2026.09.20.2

- El aviso de actualización vuelve a aparecer al abrir el menú de Borges cuando hay una versión pendiente.
- El aviso espera si se cierra el menú durante la consulta y solo se marca como mostrado después de abrirse correctamente.

## 2026.09.20.1

- Borges habla el idioma de tu KOReader. Con KOReader en castellano todo sigue igual; en cualquier otro idioma el plugin aparece entero en inglés, menús, avisos y mensajes de error incluidos.
- Los avisos que antes salían siempre en inglés (inicio de sesión, Dropbox, actualizador) ahora también están en castellano.
- Si cambiás el idioma de KOReader, el plugin cambia con él sin reiniciar.

## 2026.09.18.14

- La pregunta para retomar la lectura aparece también con «Sincronizar sola» apagado. Ese ajuste ya no impide consultar la última posición al abrir, despertar o reconectar el lector.
- Tu progreso sigue pendiente hasta consultar y elegir; ninguna posición se cambia sin tu confirmación.

## 2026.09.18.13

- Al abrir o retomar un libro, preguntamos dónde seguir si la última lectura fue en otro dispositivo, aunque esté más atrás o en la misma posición. Si fue en este lector, no preguntamos.
- Consultamos antes de enviar el progreso, también en «Sincronizar ahora». Cerrar, suspender, reiniciar o perder la conexión conservan lo pendiente sin tapar la lectura del otro aparato.
- Tanto «Ir a esa posición» como «Seguir aquí» guardan tu elección antes de enviarla. Si se corta la conexión, no perdemos esa decisión.
- Una actualización de pantalla en el mismo lugar del libro ya no se registra como una nueva lectura.

## 2026.09.18.12

- Si la posición guardada en otro lector está más adelante en el libro, vuelve a aparecer la pregunta para ir ahí aunque una marca local tenga una hora posterior.
- Comprobamos la ubicación dentro del libro y respetamos «Seguir aquí». Nunca cambiamos de página sin tu confirmación.

## 2026.09.18.11

- Al abrir o retomar un libro, conservamos la referencia de lectura anterior mientras conecta el Wi-Fi y responde Borges. Una actualización de página durante esa espera ya no oculta el aviso de otro lector.
- Seguimos pidiendo confirmación antes de cambiar de posición y descartando las lecturas que ya eran anteriores al retomar el libro.

## 2026.09.18.10

- En Kobo y Kindle, Borges conecta directamente al abrir o retomar un libro, evitando la espera de la restauración automática de KOReader.
- Al iniciar esta versión con una cuenta configurada, desactivamos esa restauración una sola vez. Podés volver a activarla en los ajustes de red de KOReader si lo preferís.
- Conservamos tus opciones de preguntar antes de conectar o seguir sin conexión, y la posibilidad de cancelar.

## 2026.09.18.9

- La sincronización hace menos trabajo al guardar sus pendientes, especialmente en lectores más lentos.
- Si nada cambió, evitamos volver a escribir la cola; el respaldo se conserva sin copiarlo entero cada vez.
- Conservamos la recuperación de datos y protegemos el guardado si se interrumpe la escritura.

## 2026.09.18.8

- Corregimos el guardado de la sincronización para conservar los eventos pendientes al reiniciar KOReader.
- Recuperamos los archivos afectados por valores nulos y guardamos copias de los originales antes de repararlos.
- Si un archivo tiene otro daño que no podemos recuperar, avisamos del error sin reemplazar la cola por una vacía.

## 2026.09.18.7

- Si falla la conexión automática al despertar, intentamos conectar una vez con las redes guardadas en KOReader, después de que termine el intento anterior.
- Se mantienen la conexión inmediata cuando ya hay Wi-Fi y la opción de cancelar y seguir leyendo.
- Respetamos las preferencias de activar, preguntar o seguir sin conexión; si la recuperación falla, nos detenemos.

## 2026.09.18.6

- Al abrir o retomar un libro, te preguntamos por la lectura más reciente de otro dispositivo, aunque esté más atrás.
- Si elegís seguir acá, recordamos tu decisión para esa actualización; una lectura posterior puede volver a avisarte.
- Buscamos primero el progreso del libro abierto, sin esperar a descargar todo el historial.
- Reconectar o reenviar una posición conserva la hora en que leíste, incluso después de leer sin Wi-Fi.
- Mantenemos las mejoras de conexión Wi-Fi y la lectura disponible mientras se sincroniza.

## 2026.09.18.5

- Buscamos tu progreso sin el cartel que tapaba la lectura e impedía pasar páginas.
- Al retomar con Wi-Fi conectado, la búsqueda empieza sin la espera adicional de un segundo.
- Mientras se conecta el Wi-Fi, podés cancelar, apagarlo y seguir leyendo sin sincronizar. El aviso se cierra al conectar.
- Buscar una actualización vuelve a mostrar una respuesta cuando falla la conexión, en vez de cerrar el cartel en silencio.

## 2026.09.18.4

- La sincronización recupera los pendientes que quedaban atascados con un error de secuencia, sin borrar ni duplicar lo guardado.
- «Sincronizar ahora» vuelve a intentar todos los pendientes, incluso después de varios fallos.
- Cada etapa de la sincronización muestra tres puntos animados mientras trabaja; las solicitudes de red se ejecutan en segundo plano.

## 2026.09.18.3

- Corregimos el cierre de KOReader al aparecer «Buscando tu progreso…» al abrir o retomar un libro.
- Se mantienen la sincronización en segundo plano y la prioridad del progreso del libro abierto.

## 2026.09.18.2

- Al abrir o retomar un libro, buscamos primero su progreso más reciente en otro lector, aunque haya mucho historial pendiente.
- Podés seguir pasando páginas mientras se sincroniza. Si la consulta tarda, aparece «Buscando tu progreso… Podés seguir leyendo».
- Elegir una posición y cerrar un libro guardan los cambios al instante y dejan los envíos en segundo plano.
- El aviso de progreso descarta los toques acumulados antes de aparecer, para evitar elecciones accidentales.
- Los subrayados y el historial siguen sincronizándose sin adelantar ni perder cambios pendientes.

## 2026.09.18.1

- La sincronización automática usa la red en segundo plano para que puedas seguir usando KOReader al arrancar.
- Si un envío pendiente falla, queda guardado para el próximo intento sin repetirlo continuamente.
- «Vincular con un código» funciona con varias cuentas: generás el código en el lector y lo ingresás desde tu cuenta de Borges en el celular o la computadora.
- El código sirve una sola vez y vence a los 5 minutos. Al terminar, el lector muestra a qué cuenta quedó conectado.

## 2026.09.17.4

- Al elegir «Ir a esa posición», vas al lugar que mostraba el cartel aunque
  lleguen más actualizaciones mientras decidís. Ya no se cancela tu elección
  con «Mientras decidías llegó una posición más nueva».
- Los avances recibidos también preguntan antes de mover el libro.
- Las posiciones de lectura web aparecen como «la web».

## 2026.09.17.3

- Los fallos repetidos de sincronización y descarga pueden informarse automáticamente para que podamos corregirlos.
- Los reportes no incluyen libros, subrayados, notas ni contraseñas. Podés desactivarlos en Estado y ayuda.
- El envío se hace en segundo plano y espera a que haya Wi-Fi; no enciende la conexión.

## 2026.09.17.2

- El servidor permite retomar la sincronización cuando el lector conserva una
  marca anterior, sin bloquearse con «Committed cursor cannot move backwards».
- Los cambios pendientes se recuperan página por página. Esta corrección del
  servidor también beneficia a las versiones anteriores del plugin.

## 2026.09.17.1

- Entrás con tu usuario y contraseña de Borges desde el lector. Ya no hace
  falta copiar una clave larga a mano.
- El menú se llama Borges y tiene una sola acción para sincronizar: antes
  había que acordarse de cuál tocar.
- Al reconectar, el lector pregunta una sola vez si querés seguir donde
  quedaste en otro aparato. Si le decís que no, no vuelve a insistir.
- Si algo falla, «Reportar un problema» te da el código de soporte de este
  lector para que podamos mirarlo.

## 2026.07.24.1

- El lector avisa cuando hay una versión nueva al reconectar el Wi-Fi o al
  abrir el menú, sin encender la radio por su cuenta.
- El aviso aparece una sola vez por versión y nunca encima de la lectura.
- «Actualización disponible» queda en el menú Borges hasta que la instales.
- La instalación sigue siendo tuya: se descarga, se verifica y recién
  entonces se ofrece reiniciar.
