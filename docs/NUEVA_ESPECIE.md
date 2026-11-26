# Cómo hacer una especie nueva (aprendido con Musgo)

Guía paso a paso y errores ya cometidos, para no repetirlos. Musgo es la especie de referencia
(`musgo()` en `tools/creatures.py`).

## 1. Referencias de Lucas

- Él genera con ChatGPT las planillas de adulto (frente, perfil, atrás, arriba, 3/4), cría (perfil y 3/4)
  y huevo. Con eso alcanza; la joven sale sola por interpolación.
- Antes de modelar, definir el **rasgo de cría** de la especie (cabeza, patas, ojos, cuernos…): es el
  que se agranda en la cría. No agrandar los ojos por defecto.
- Escala: medir en la imagen en píxeles y pasar a studs (Musgo: ~30 px = 1 stud). El jugador de
  Roblox mide 5 studs.

## 2. Modelo (`tools/creatures.py`)

- Solo cajas. Cada caja = una pieza rígida con Motor6D. Medidas en múltiplos de 0.25 stud.
- **Nombres que el animador reconoce** (si se respetan, todo funciona sin código nuevo):
  `Rear` (raíz del cuerpo, caderas), `Chest` (cuelga de Rear: flexión de columna),
  `Neck1`/`Neck2`/`Head` (o `Neck`/`Head`), `LegFU/LegFL/LegBU/LegBL` + `L`/`R` (muslo y caña),
  `Tail1..N`, `Ant1/Ant2` + `L`/`R` (antenas), `Beard1/Beard2` (colgantes).
- La criatura mira a **-Z**. `mirrored()` define el lado **derecho (+X)**; el izquierdo se espeja,
  incluidas las rotaciones Y/Z.
- Signos de rotación X: positivo = la punta de una pieza que cuelga va hacia adelante (-Z); para una
  pieza que apunta hacia adelante, positivo = sube.
- `baby=` por pieza: número o `(x, y, z)` (por ejemplo, cuerpo más corto en la cría). La
  interpolación usa la curva `1-(1-edad)^2`: la joven ya tiene casi las proporciones adultas
  (con la recta, la joven quedaba cabezona).
- Cola de la cría: muy corta (`baby` 0.3–0.5), si no queda larguísima.
- Pintura: `skin=dict(belly=…, moss=…, mossTop=True)` con las rampas `body`/`belly`/`moss`. Los
  colores se ven más fríos/lila con la luz de Roblox: usar rosas/colores más cálidos que la referencia.
  Manchas grandes y pocas (densidad ~0.4); con más se ve como ruido de camuflaje.
- El huevo es otra "especie" de capas en cruz (`huevo_musgo()`); el animador lo detecta por `Capa1`.

## 3. Textura

- `uv run --with pillow tools/creatures.py` genera atlas + JSON.
- Subir el atlas: servir `assets/textures` con `python -m http.server 8765` (vía `uv run`) y usar
  `upload_image` del MCP de Studio con `http://127.0.0.1:8765/<archivo>?v=N`. Pegar el id en
  `src/shared/Textures.luau`. Cada cambio de atlas = subida nueva (id nuevo).
- Registrar la especie en `src/shared/Creatures/Species.luau` y sus números en
  `src/shared/Creatures/SpeciesStats.luau` (velocidades, salto, vida, stamina, daño, tiempos de
  levantarse).

## 4. Animación (ya es genérica, no hay que tocarla si se respetan los nombres)

`src/shared/Creatures/CreatureAnimator.luau`, corre en el cliente.
Errores que ya se resolvieron y no hay que reintroducir:
- Actualizar en **PreSimulation**, no en PreRender: con PreRender el cuerpo tironeaba, y además
  Studio lo frena cuando la ventana no tiene foco.
- La Root de los NPC llega del servidor a saltos (~15/s): se suaviza en el cliente (dos filtros,
  tasa 8). Con tasa 20 quedaban tirones.
- Los modelos tienen que ser **ModelStreamingMode Atomic** y el cliente esperar a que llegue
  `PrimaryPart`; si no, con streaming no se anima nada.
- Medidas (largo de pata, etc.) desde la **pose de reposo** (C0/C1), nunca desde las posiciones vivas.
- Los resortes llevan **subpasos**: sin eso, un cuadro lento los hace explotar (las patas
  "salían volando").
- Los apéndices (antenas, barba) reciben la inercia **filtrada** y con más amortiguación al moverse;
  si no, vibran al caminar.
- El IK busca el suelo **donde está el pie** (no bajo la cadera), con rayos que ignoran a todas
  las criaturas.

## 5. Jugable (`PlayAsCreature` + `CreatureControls`)

- El personaje es el modelo con Humanoid. La Root se sube a la altura del cuerpo (compensando los C0)
  y `HipHeight` = altura del cuerpo − media caja. Con la Root al ras del piso, en la cría daba
  HipHeight negativo y el Humanoid fallaba.
- Al aparecer, buscar el suelo con un rayo: la superficie del terreno no está donde dice el
  generador (en el corral está 2 studs más arriba), y aparecer adentro del terreno = caer al vacío.
- Saltar: `JumpPower` en 0 y salto propio (carga 0.22 s y `ChangeState(Jumping)`). `Humanoid.Jump =
  true` no sirve porque el script de controles de Roblox lo pisa cada cuadro.
- Clic derecho = cámara en Roblox: el cabezazo se decide al soltar (clic corto, sin arrastrar).
- Shift: `EnableMouseLockOption = false` (si no, Shift bloquea la cámara en vez de sprintar).
- Los golpes no pegan al propio grupo (atributo `Grupo`).

## 6. IA (`CreatureAI.server.luau`)

- Atributos en el modelo: `IA = true`, `Grupo`, `Rol` (`Madre`/`Lider`/`Cria`/`Joven`/`Solo`).
- Usa los números de `SpeciesStats`; una especie nueva con otro temperamento se ajusta en los
  puntajes de `think()`.

## 7. Probar en Studio (con el MCP)

- Si Rojo se desconecta, Studio no recibe cambios: comparar tamaños de `Source` contra los archivos
  y, si hace falta, aplicar con `multi_edit`. Pedirle a Lucas que reconecte el plugin.
- `require` desde `execute_luau` en modo edición queda **cacheado**: para reconstruir con código
  nuevo, clonar `Shared` (renombrando el original) y el servidor.
- En Play, las conexiones creadas desde `execute_luau` en el **servidor** mueren al terminar el
  comando; las del cliente sobreviven. Las demos de movimiento se manejan desde el cliente.
- No se pueden simular teclas reales: `Humanoid:Move` lo pisan los controles. Para moverse, usar
  `Humanoid:MoveTo`; para los botones, llamar al remote directo.
- Pasar `Terrain.Decoration = false` en zonas de prueba (el pasto alto tapa las patas).
- Si Lucas está en Play, no cortarlo: avisarle y esperar.
- Medir antes de mostrar: patinaje de patas, hueco pata-suelo, saltos de altura y vida/regeneración.
  Después, captura o video (los videos quedan en `C:\Users\Usuario\Pictures\LUCAS`, y Lucas los abre
  desde ahí).

## 8. Más errores resueltos (ronda de pulido)

- Patas con pie fijo (quieta, atacando o excavando): apuntar la pata al pie con una **rotación real**
  (`CFrame.fromAxisAngle`). Componer el adelante-atrás y el costado como dos ángulos sueltos falla con
  ángulos grandes y el pie no llega (patinaba 0.8–1.8 studs; ahora 0.05–0.17).
- Cola enroscada: girar primero hacia el costado y después inclinar (`fromEulerAnglesYXZ`); en el otro
  orden la cola no baja al suelo. Además hay una corrección medida por bloque hasta tocar el suelo.
- Salto: para saber si está en el aire, usar el **estado del Humanoid** (Jumping/Freefall).
  `FloorMaterial` sigue viendo el piso en saltos bajos de criaturas con patas largas. Durante el salto
  la gravedad baja al 55% con un VectorForce, para que el arco sea más lento y pesado.
- Pose en el aire: mezclar subiendo/bajando de forma continua según la velocidad vertical; con un
  if subida/bajada las patas saltaban de golpe en la cima.

## 9. Sonido y partículas

- Los efectos viven en `src/client/CreatureFX.luau` (lista `SOUNDS` con los ids). El animador avisa
  los momentos (`onEvent`): una especie nueva los recibe sola si respeta los nombres de piezas.
- Audio con el grafo nuevo (AudioPlayer -> Wire -> AudioEmitter en un Attachment). **No** existe
  `SoundService.ListenerLocation`: es `DefaultListenerLocation` y ya viene en Camera (Roblox crea el
  oyente solo). Esa línea rompía el script y dejaba a TODAS las criaturas sin animar: por eso
  `CreatureFX` se carga con `pcall` en `CreatureAnimation`.
- Antes de usar un sonido, verificar que carga (`AudioPlayer.IsReady`). ProSoundEffects (Creator
  Store) es la fuente segura; para pisadas de pasto no tenía, se usaron otras gratuitas.
- Pisadas: mínimo 0.22 s entre pasos de la misma pata y solo avanzando de verdad; si no, el límite
  apoyo/vuelo titila y suenan decenas por segundo.
- Partículas: texturas pixeladas propias (`tools/gen_particles.py`). Si son rápidas y chicas no se ven:
  terrones de 0.65 studs, vida de 0.7–1.1 s.
- Estilo de sonido elegido por Lucas: realista y suave. Musgo no tiene boca: su voz es solo
  respiración y resoplidos (la voz propia se define cuando haya más especies).

## 10. Aprendido con la especie 2 (Grieta)

- El constructor apoya en el suelo la pieza **más baja**: si la cola en reposo baja más que las patas, la
  criatura queda flotando. La curva de la cola en reposo tiene que terminar a la altura de los pies
  (Grieta: Tail1 0°, las demás 5°).
- Los rojos también se aclaran con la luz de Roblox (se veían salmón): usar rampas más oscuras que la
  referencia, igual que pasó con el rosa de Musgo.
- Una pieza que la animación no conoce (pétalos de la boca) necesita su propio bloque en el animador.
  Los ataques de cada especie van en `SpeciesStats` (`primary`, `secondary`, `frontAttack`); los
  controles, la guía y la IA los leen de ahí.
- Piezas en anillo (pétalos, dientes): la orientación radial va en el C0 (`rot=(0, 0, -ángulo)`) y la
  inclinación hacia adelante se anima con `Transform`; con ángulos Euler en el C0 no se puede componer
  bien "girar en el anillo y después inclinar".
- Rojo: si Studio no recibe los cambios aunque el plugin diga conectado, el servidor de Rojo quedó
  trabado. Levantar otro con `rojo serve --port 34873` y pedirle a Lucas que cambie el puerto en el
  plugin.
- El zoo es una lista `PENS` en `ZooBuilder`: especie nueva = una entrada más.
- Salto hacia adelante: el Humanoid frena lo horizontal en el suelo **y en el aire** si no hay tecla
  apretada. Un empujón suelto no sirve (avanzaba ~1 stud): hay que mantener la velocidad hacia
  adelante durante el vuelo (`leapUntil` en CreatureControls). `jumpForward` por especie.
- Piezas decorativas sin animar (cintura, nuca de la cabeza, dientes) se pueden agregar libremente;
  la animación solo mira los nombres que conoce.

## 11. ERROR GRAVE con Grieta: la hice cuadrúpeda y era BÍPEDA

- Antes de modelar, **contar las patas en TODAS las vistas** (frente, atrás, arriba, perfil) y escribirlo
  ("frente: 2 patas, atrás: 2, arriba: 2 → bípeda"). En el perfil, un muslo inclinado + caña + pie se
  puede confundir con dos patas: el frente y la espalda mandan.
- Confirmarle a Lucas la lectura de la planilla (cantidad de patas, partes) ANTES de modelar.
- El animador ya soporta bípedas: patas `LegBU/LegBL` + `L/R` sin delanteras → `self.biped`. Camina
  alternando, el galope también alterna, el terreno usa un rayo extra adelante para la pendiente, y
  excava con el hocico (baja el pecho y la cabeza). El pie es una pieza hija de la caña, al ras de su base.
- Para capturas en Play con la criatura del jugador: la cabeza sigue a la cámara. Sacar el atributo
  `Jugador` del modelo en el cliente para que mire adelante.
- Patas dobladas en reposo (muslo adelante, caña atrás, como Grieta): se pueden, siempre que el
  **tobillo quede justo debajo de la cadera** (calcular los ángulos: rodilla adelante = largo_muslo·sen(θ1),
  y la caña vuelve lo mismo atrás). El animador mide a, b y D0 (cadera-tobillo) y gira respecto del reposo.
- Pie aparte (pieza `Foot` hija de la caña, al ras del tobillo): el animador lo mantiene plano. Sin eso, el pie
  gira con la caña y la punta o el talón se hunden en el suelo (pasaba 0.23 studs).
- Comparar las patas con la planilla de cerca (captura con zoom) antes de dar el modelo por bueno.
- Comparar con una imagen lado a lado (planilla | captura en Play de perfil con FieldOfView 30, cabeza a
  la izquierda como la planilla) armada con ffmpeg `hstack`, y corregir hasta que coincida: posición del
  muslo a lo largo del cuerpo (Grieta: al centro), altura del cuerpo, altura de la cabeza, curva de la cola.
- No agregar piezas que no están en la planilla (los "hombros" de Grieta parecían brazos: Lucas no los quería).
- Tamaño de especie: `"scale"` en la definición (tools/creatures.py) escala medidas, articulaciones y
  pivotes antes de pintar (misma densidad de píxeles). Grieta = 0.6 (la mitad de Musgo). `babySize` define
  cuánto más chica es la cría (Grieta 0.65: poca diferencia entre etapas; Musgo 0.38).
- El constructor y el animador apoyan la criatura sobre las patas (Leg/Foot/Toe/Claw/Paw) si las tiene:
  una cabeza o boca grande de cría quedaba más baja que los pies y la dejaba flotando.
