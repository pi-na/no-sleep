# Wi‑Fi fallback — diseño

Fecha: 2026-11-20 · Estado: borrador para aprobar

## Intención

Tomas trabaja en un café con agentes corriendo, se levanta, cierra la Mac y la guarda en la mochila. El Wi‑Fi del café queda fuera de alcance y los agentes se quedan sin internet hasta que el *offline failsafe* suelta la Mac a los 15 minutos. Lo que quiere es que la Mac pase **sola**, sin pantalla y sin que la toque, a una red de respaldo elegida entre las que ya conoce: en la práctica, el hotspot de su iPhone, que va bloqueado en el bolsillo.

macOS no lo hace por su cuenta: a los hotspots personales no los elige por auto‑join, y el iPhone bloqueado no emite su red; solo aparece por *Instant Hotspot* (Bluetooth + iCloud), que es API privada.

## Objetivos

- Toggle **Wi‑Fi fallback** en el menú; la red se elige en Settings entre las redes conocidas de la Mac.
- Si se pierde internet, unirse a esa red en menos de ~1 minuto, también con la tapa cerrada y el iPhone bloqueado.
- Funciona siempre que el toggle esté prendido (no solo con agentes).
- Settings explica cómo dejar el iPhone listo y pide el permiso de Accesibilidad.

## No‑objetivos

- Volver a forzar la red principal: cuando aparece una red conocida, macOS ya vuelve sola (se vio en la prueba).
- Varias redes de respaldo en orden de prioridad.
- Ethernet, VPN, Low Data Mode, comando en la CLI.
- Usar frameworks privados de Apple.

## Anti‑objetivos (aunque "ande", sería un fracaso)

- Pelearse con el usuario: si él apagó el Wi‑Fi o se conectó a mano a otra red con internet, no tocar nada.
- Un menú de Wi‑Fi que se abre y se cierra en loop delante del usuario cuando la Mac está abierta. Los intentos visibles tienen que ser pocos y espaciados.
- Quedarse colgado reintentando para siempre o gastar batería en la mochila: el *offline failsafe* sigue mandando.

## Restricciones y lo que mostró la prueba (2026-11-20, macOS 14.8)

- Las redes conocidas se leen sin permisos: `networksetup -listpreferredwirelessnetworks <if>` (la interfaz sale de `networksetup -listallhardwareports`, puerto "Wi‑Fi").
- Vía pública: `networksetup -setairportnetwork <if> <SSID>` usa la clave del llavero. Con el iPhone bloqueado falló ("Could not find network").
- Vía Instant Hotspot: el menú de Wi‑Fi de `ControlCenter` (menu bar extra cuya descripción empieza con "Wi") lista cada red como `AXCheckBox` con `AXIdentifier = "wifi-network-<SSID>"`, independiente del idioma. Abrirlo, esperar ~3 s y presionar ese elemento **unió la Mac a "pina" en ~5 s con la tapa cerrada y el iPhone bloqueado.**
- A los 5 s de unirse todavía no había internet (probablemente DHCP del iPhone): hay que darle un margen (~20 s) antes de declarar el intento fallido.
- Con la tapa cerrada: no se sabe si la pantalla estaba bloqueada durante la prueba. Hay que verificar que el clic por accesibilidad anda con la sesión bloqueada, y si no, documentarlo (Go Dark ya evita el bloqueo).
- La app sale para macOS 14, 26 y 27; el árbol del menú puede cambiar entre versiones. Hay que verificarlo en 26 antes del release.
- El permiso de Accesibilidad queda atado a la firma; la identidad autofirmada es estable entre builds, así que sobrevive a las actualizaciones.

## Enfoques considerados

1. **Solo vía pública** (`networksetup`). Sin permisos y estable, pero no anda con el iPhone bloqueado, que es justamente el caso de Tomas.
2. **Vía pública + clic en el menú de Wi‑Fi por accesibilidad** ← **elegido.** Es lo único que despierta el iPhone bloqueado. A cambio pide permiso de Accesibilidad y es frágil entre versiones de macOS, lo que se mitiga buscando por `AXIdentifier` y avisando en el menú si no se encuentra la red.
3. **Agente con computer use.** Descartado: necesita internet para hablar con el modelo (justo lo que falta) y ver la pantalla (apagada con la tapa cerrada).

## Diseño

### Detección

- El fallback actúa **solo mientras la Mac está despierta** por otra razón (No Sleep activo, o simplemente en uso). No mantiene la Mac despierta por su cuenta: si nada la sostiene, se duerme en la mochila y no hay nada que salvar. *(decisión de Claude)*
- Disparo: el toggle está prendido, el Wi‑Fi está encendido y **no hay internet durante 30 s seguidos**. "Sin internet" es: sin ruta en `NWPathMonitor`, o el probe de `captive.apple.com` falla por error de red o timeout.
- **Portal cautivo no dispara** *(decisión de Claude)*: si el probe recibe una respuesta HTTP que no es la de Apple (página de login de un hotel o café), el usuario probablemente está entrando a esa red; no se lo saca de ahí.
- `Connectivity` hoy prueba solo mientras hay agentes; pasa a probar también **mientras el fallback está prendido**: un GET cada 30 s.
- Si la Mac ya está en la red de respaldo, no se dispara (no hay nada mejor que hacer).
- **Red actual sin permiso de Ubicación** *(decisión de Claude)*: desde macOS 15 el SSID actual queda oculto para apps sin Ubicación (`networksetup -getairportnetwork` y CoreWLAN dejan de darlo). No se pide ese permiso. La red actual se lee, en este orden, de `networksetup -getairportnetwork` (anda en 14) y del menú de Wi‑Fi, donde el `AXCheckBox` de la red conectada tiene `AXValue = 1` (verificado en 14.8). Si ninguno la da, la política funciona igual: el éxito se mide por internet, no por el nombre.

### Intento (un "ciclo")

1. Vía pública: `networksetup -setairportnetwork`. Si la red actual pasa a ser el SSID, esperar internet hasta 20 s.
2. Si no: vía accesibilidad. Abrir el menú de Wi‑Fi, buscar `wifi-network-<SSID>` (hasta ~5 s, sondeando), presionarlo; si no aparece, cerrar el menú (Escape / volver a presionar el ítem). Esperar a que la red actual sea el SSID (hasta 30 s) y luego internet (hasta 20 s).
3. Éxito = internet de vuelta (con cualquier red). Fracaso → siguiente ciclo tras 1 min y luego 3 min. **Tope: 3 ciclos** (~5 min). Después se rinde hasta que vuelva internet o cambie la red, y el menú lo dice. Así no queda abriendo el menú de Wi‑Fi para siempre cuando no hay agentes ni failsafe que lo corte. Corta antes si vuelve internet o se apaga el toggle o el Wi‑Fi. *(decisión de Claude)*
4. Toda la secuencia corre fuera del main thread; los procesos `networksetup` llevan timeout.

### Convivencia con el offline failsafe

Sin acoplamiento. El fallback actúa en el primer minuto; si recupera internet, el contador del failsafe se reinicia solo (ya lo hace hoy). Si no, el failsafe suelta la Mac a los N minutos como siempre.

### Menú

Sección propia, como *Screen glow*: título **Wi‑Fi fallback** + switch, y debajo una línea de estado chica:

```
Wi‑Fi fallback                         [ ON ]
  Si se cae internet, se une a "pina"
```

Estados de la línea: *Si se cae internet, se une a "X"* · *Conectando a "X"…* · *Conectado a "X" a las 19:02* · *No se encontró "X". Reintenta en 2 min* · *Falta elegir una red* / *Falta el permiso de Accesibilidad* (estos dos abren Settings).

### Settings

Sección **Wi‑Fi fallback**:
- Picker con las redes conocidas (se refresca al abrir Settings).
- Fila de permiso de Accesibilidad: estado + botón que llama a `AXIsProcessTrustedWithOptions` con prompt y abre el panel de Privacidad.
- Bloque *iPhone*: "Mismo Apple ID en la Mac y el iPhone, Bluetooth y Wi‑Fi prendidos en los dos. En el iPhone, Hotspot personal → activá **Maximizar compatibilidad** (2,4 GHz, engancha mejor) y **Permitir que otros se conecten**."
- Botón **Probar ahora**: corre un ciclo aunque haya internet. Ahí el éxito es "la red actual es la de respaldo y hay internet" (no alcanza con "hay internet"). Deja la Mac en el hotspot, sin volver atrás; el resultado se ve en Settings. *(decisión de Claude)*

### Estructura del código

- `NoSleepCore/WiFiFallbackPolicy.swift` — lógica pura y testeable: cuándo disparar, qué paso sigue, backoff. Tests en `NoSleepSelfTest`.
- `NoSleepApp/System/WiFi.swift` — interfaz Wi‑Fi, redes conocidas, red actual, join por `networksetup`.
- `NoSleepApp/System/InstantHotspot.swift` — clic en el menú por `AXUIElement` (API de Swift, no AppleScript: así solo pide Accesibilidad, no además Automatización).
- `NoSleepApp/WiFiFallback.swift` — `@Observable`, orquesta política + sistema y expone el estado al menú.
- Preferencias en `UserDefaults` como el resto: `wifiFallbackEnabled` (por defecto **apagado**) y `wifiFallbackSSID`.
- README: una viñeta en *What it does*.

## Qué queda a criterio del builder

Nombres internos, el orden exacto para cerrar el menú si no se encontró la red y los textos finales en inglés (la UI de la app está en inglés; los textos de arriba son guía).

## Verificación

- Selftest de la política (disparo, pasos, backoff, no disparar con Wi‑Fi apagado o ya en la red de respaldo).
- Prueba real repitiendo la de la prueba descartable, desde la app: tapa cerrada, iPhone bloqueado, forzar el paso con **Probar ahora** y con una pérdida real del Wi‑Fi del café.
