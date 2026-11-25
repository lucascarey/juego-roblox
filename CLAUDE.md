# Juego Roblox — reglas de trabajo

## Fuente de verdad
- El repo Git es la única fuente de verdad del código.
- Los scripts **nunca** se editan a mano en Studio. Rojo sincroniza los archivos de `src/` hacia Studio (`rojo serve` + plugin Rojo).
- El MCP integrado de Studio se usa **solo** para hacer playtest, leer la consola y sacar capturas. Nunca para escribir scripts.

## Estructura (default.project.json)
- `src/server` → `ServerScriptService.Server`
- `src/client` → `StarterPlayer.StarterPlayerScripts.Client`
- `src/shared` → `ReplicatedStorage.Shared`
- `Packages` → `ReplicatedStorage.Packages` (Wally, realm shared)
- `ServerPackages` → `ServerScriptService.ServerPackages` (ProfileStore)
- `DevPackages` → `ReplicatedStorage.DevPackages` (Jest-Lua, solo tests)
- `tests/` → tests

Herramientas fijadas en `rokit.toml` (rojo, wally, selene, stylua, lune). Tras clonar: `rokit install` y `wally install`.

## Flujo de cada cambio (pasos chicos)
1. Escribir/editar archivos en `src/`.
2. `selene .` + `stylua .` (y `stylua --check .`) + revisar tipos con luau-lsp.
3. Tests (Jest-Lua).
4. Playtest en Studio (vía MCP: play, consola, capturas).
5. `rojo build -o build/test.rbxl` para confirmar que compila.
6. Commit pequeño con mensaje claro.

## Diseño
- Biblia del juego: https://claude.ai/artifact/6pSSDuKiKy19V2KNmUrsMA
- Estilo de arte: low-poly facetado y colorido. Las criaturas se construyen con piezas rígidas sobre un esqueleto Motor6D con patas IK.
