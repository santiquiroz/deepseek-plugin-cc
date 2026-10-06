# deepseek-plugin-cc

Delega tareas de código desde [Claude Code](https://claude.com/claude-code) a
la CLI de [DeepSeek Harness](https://www.deepseek.com/) (`dsh`) en modo headless.

Claude Code sigue siendo el orquestador — escribe la lógica de dominio, define
el contrato de cada subtarea y revisa los diffs. DeepSeek Harness es **el primer
carril agéntico preferido**: el delegado lee y edita archivos y ejecuta comandos
en tu repositorio, bajo un sandbox a nivel de SO confinado al directorio de
trabajo, y `--read-only` rechaza ediciones para revisiones y diagnósticos que no
deben tocar el árbol de trabajo. `deepseek-flash` cubre trabajo mecánico y
`deepseek-v4-pro` cubre trabajo de razonamiento; la facturación es el saldo de
tu plataforma DeepSeek (pago por uso).

Hermano de [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc),
[antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc),
[ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc),
[cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) y
[bipolar-plugin-cc](https://github.com/santiquiroz/bipolar-plugin-cc), todos
inspirados en la estructura de [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc).
**No está afiliado con DeepSeek, OpenAI, GitHub, Google ni Anthropic.**

> Read this in English: [README.md](README.md)

## Dónde encaja en una cadena de delegación

| Nivel | Delegado | Sirve para |
|---|---|---|
| trivial | [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc) | transformaciones de texto de un solo paso en un modelo local pequeño |
| medio (local) | [bipolar-plugin-cc](https://github.com/santiquiroz/bipolar-plugin-cc) | tareas agénticas acotadas en un modelo local grande |
| **primer carril** | **deepseek-plugin-cc (este)** | trabajo mecánico con `deepseek-flash`, trabajo de razonamiento con `deepseek-v4-pro`; preferido sobre los otros carriles en la nube |
| mecánico (fallback) | [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc) | boilerplate, renombres, specs simples, limpieza |
| carril agéntico extra | [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) | tareas acotadas cuando los otros carriles se quedaron sin cuota, segundas opiniones en solo lectura |
| frontier, segundo carril | [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc) | fallback de Codex, segundas opiniones |
| frontier, primario | Codex / tu delegado principal de razonamiento | implementación cercana a arquitectura, diagnóstico profundo |

Solo existen los carriles que instales; el plugin también funciona solo.

## Requisitos

- Claude Code. El forwarder corre a través de la herramienta Bash (Git Bash en Windows).
- La app de escritorio [DeepSeek Harness](https://www.deepseek.com/) — verificada en
  **0.2.0-rc.2** (Windows 11). Con sesión iniciada una vez (el token de cuenta se
  lee de `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml`), o con una `DEEPSEEK_API_KEY`
  exportada en el entorno.

## Instalación

En Claude Code:

```
/plugin marketplace add santiquiroz/deepseek-plugin-cc
/plugin install deepseek@deepseek-plugin-cc
```

Luego, una vez por máquina:

```
/deepseek:setup
```

Setup localiza el CLI, comprueba la versión y el provider/inicio de sesión, y te
dice cómo arreglar cada uno cuando falta.

## Uso

```
/deepseek:rescue add unit tests for src/utils/money.ts covering rounding and negative amounts (signatures pasted below) ...
/deepseek:rescue --background rename UserDto to UserResponse across src/api and update the imports
/deepseek:rescue --read-only review src/services/billing.ts for race conditions; report only
/deepseek:rescue --model deepseek-v4-pro diagnose this build failure across the module graph ...
```

### Flags y límites

Pon los flags primero, luego el texto de la tarea.

- `--wait` (por defecto) — foreground. Claude Code espera un job desacoplado
  de `dsh` mediante llamadas `wait` sucesivas. Si interrumpes el subagente, el
  job sigue corriendo; conserva su id para esperar o cancelarlo después.
  Las ediciones quedan en tu árbol de trabajo.
- `--background` — el subagente corre en segundo plano y su salida se retransmite
  cuando termina la ejecución. Úsalo para cualquier cosa que dure más de un minuto.
- `--model <slug>` — `deepseek-flash` (por defecto, trabajo mecánico) o
  `deepseek-v4-pro` (trabajo de razonamiento).
- `--read-only` — ejecuta `DSH_PERMISSION_MODE=read-only`: se rechazan las
  ediciones de archivos. Pega el diff o el código en la tarea en lugar de pedirle
  al delegado que corra `git diff`.
- `--continue` — reanuda la última ejecución delegada en este repo. El subagente
  lo agrega automáticamente cuando tu pedido claramente continúa trabajo delegado
  previo ("continue", "keep going", "resume").

Las ejecuciones duran hasta `DEEPSEEK_RESCUE_MAX_SECONDS` (por defecto 2700
segundos, 45 minutos). `start` desacopla el job y `wait` lo espera en tramos de
480 segundos (máximo 540), cada uno en una llamada Bash foreground separada con
timeout 600000 ms, nunca `run_in_background`. El presupuesto es
`1 + 1 + ceil(MAX/480) + 1` llamadas. El tope anterior de 9 minutos
(`timeout -k 10 540`) dejaba margen bajo el techo de 600 segundos de Bash;
`run` conserva ese tope como vía corta. El subagente pide `--json` e imprime
solo el progreso nuevo de cada tramo — texto del asistente, una línea por llamada
a herramienta, una línea por denegación. Un `wait` pasado el plazo mata el árbol
de procesos con exit 124; `cancel <id>` lo hace con exit 130. Las ediciones
hechas hasta entonces quedan en tu árbol de trabajo.

## Delegación proactiva

La descripción del agente `deepseek-rescue` le dice a Claude Code que lo use por
su cuenta como primer carril. Esa ejecución envía el texto de la tarea al backend
de DeepSeek y deja que el modelo edite archivos en el repositorio actual dentro de
un sandbox confinado al espacio de trabajo. Lo que se interpone entre eso y tu
árbol de trabajo es el sistema de permisos propio de Claude Code: la única
herramienta del subagente es `Bash`, así que en el modo de permisos por defecto
apruebas el comando de lanzamiento antes de que corra, mientras que bajo bypass
mode corre sin preguntar. Si quieres delegación solo bajo pedido, omite el
snippet de CLAUDE.md y agrega esta línea a `~/.claude/CLAUDE.md`:

```
Never launch deepseek:deepseek-rescue on your own; use it only when I invoke /deepseek:rescue explicitly.
```

Para que la delegación proactiva sea rutinaria, pega el bloque de
[docs/claude-md-snippet.md](docs/claude-md-snippet.md) en tu `CLAUDE.md`;
la división de carriles, los topes de WIP y la cadena de fallback están en
[docs/delegation-guide.md](docs/delegation-guide.md).

## Qué ejecuta realmente el forwarder

El subagente llama `preflight`, `start` y sucesivos `wait` mediante
`scripts/deepseek-forward.sh`, que concentra cada paso determinista (probado con
un `dsh` falso en `tests/run.sh`). Cada comando es una llamada Bash separada:

```bash
bash scripts/deepseek-forward.sh preflight [--model <slug>]
bash scripts/deepseek-forward.sh start --model <slug> [--read-only] [--continue] <<'DEEPSEEK_TASK_<nonce>'
<your task, verbatim>
DEEPSEEK_TASK_<nonce>
bash scripts/deepseek-forward.sh wait <id>
```

`preflight` encuentra el launcher, lee la versión y resuelve el provider
(`deepseek-account` cuando la app de escritorio tiene sesión iniciada, si no
`deepseek-official` cuando `DEEPSEEK_API_KEY` está definida, si no falla con exit
70). `start` escribe el patch y la tarea en
`${DEEPSEEK_RESCUE_HOME:-$HOME/.deepseek-rescue}/jobs/<id>/`, agrega el párrafo de
restricciones, guarda el estado de git y lanza un wrapper con `nohup`, background
y `disown`. Imprime `[deepseek-rescue] started job <id>` y sale inmediatamente.
El wrapper ejecuta (en Windows el app exe se llama
directamente, nunca el shim `.cmd`, que reinterpreta los argumentos a través de
cmd.exe):

```bash
ELECTRON_RUN_AS_NODE=1 DSH_PERMISSION_MODE=workspace-write GIT_TERMINAL_PROMPT=0 \
GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
"<app exe>" --expose-internals "<cli.js>" \
  --profile headless --patch <job>/patch --json [--session-id <id>] - <tarea por stdin>
```

`wait` pasa solo las líneas completas nuevas de stdout a `scripts/stream-filter.js`.
Exit 75 significa volver a llamar `wait <id>`. Al terminar imprime el progreso
restante, stderr filtrado, el resumen y una línea `[deepseek-rescue] WARNING:
<what changed> — review before your next git command` cuando la ejecución movió
`HEAD`, cambió de rama, alteró la lista de stash, git config o hooks (informa,
nunca revierte). Recuerda el id de sesión y limpia los archivos temporales del
job al terminar. Para detenerlo, usa `bash scripts/deepseek-forward.sh cancel <id>`.

## Modelo de seguridad

Hechos sobre `dsh` headless en los que se basa este plugin (verificados en
0.2.0-rc.2, Windows 11):

- La tarea viaja por stdin (`-`), nunca por la línea de comandos, así que no hay
  límite de longitud de argv.
- `DSH_PERMISSION_MODE` es `read-only`, `workspace-write` (por defecto) o
  `danger-full-access`. `workspace-write` confina las escrituras al directorio de
  trabajo actual mediante un sandbox a nivel de SO; una escritura fuera de él falla
  con `[sandbox: file access denied under workspace-write mode]`. La política de
  aprobación es `ask` tanto en `read-only` como en `workspace-write`, y headless no
  tiene quién responda, así que cada solicitud de escalado falla cerrada.
- `danger-full-access` significa aprobación `never` y **sin sandbox**. El forwarder
  lo rechaza (exit 64) sin importar cómo llegue — por `DSH_PERMISSION_MODE` o por
  `--permission`.
- El directorio de trabajo **es** la raíz del workspace (el CLI usa
  `process.cwd()`).
- El sandbox **no** bloquea red ni git dentro del workspace (`.git` está dentro),
  así que el párrafo de restricciones sigue prohibiendo commit, push, reset,
  checkout, clean, cambio de rama y borrado de archivos.
- `--session-id <id>` reanuda una sesión persistida existente y da error si el id
  es desconocido, si la sesión se grabó en un directorio de trabajo distinto, o si
  es una sesión de subagente. El forwarder recuerda el id de sesión de cada
  ejecución en `~/.deepseek-rescue/sessions/<sha1 de $PWD>` y `--continue` lo pasa
  de vuelta.

Lo que esto **no** cubre — conócelo antes de delegar:

- Los comandos de shell corren como tu usuario del SO y pueden alcanzar cualquier
  ruta en disco. El delegado edita tu árbol de trabajo en vivo; no edites los
  mismos archivos mientras una ejecución `--background` está en curso. Haz commit
  o stash de tu propio trabajo primero.
- Web fetch y los comandos de red no están denegados. No delegues tareas que
  procesen contenido no confiable.
- Un delegado aún puede hacer commit, cambiar de rama o stash pese al párrafo de
  restricciones. El forwarder compara `HEAD`, rama, stash, git config y hooks antes y
  después e imprime una línea `WARNING` por cada cambio. Trata el párrafo como una
  barandilla, no como un sandbox.

## Comportamientos conocidos del CLI de DeepSeek que este plugin mitiga

| Comportamiento (0.2.0-rc.2) | Manejo |
|---|---|
| `dsh.cmd` pasa argumentos a través de `cmd.exe`, que reinterpreta las comillas | el app exe se llama directamente con `ELECTRON_RUN_AS_NODE=1` y `--expose-internals <cli.js>` |
| `ELECTRON_RUN_AS_NODE=1` convierte el app exe en un runtime de Node | el filtro de stream también corre sobre ese exe, así que no se requiere un `node` aparte |
| No hay flags de CLI para modelo/provider; el perfil headless usa por defecto `deepseek-official` y falla `MISSING_CREDENTIAL` sin `DEEPSEEK_API_KEY` | un overlay `--patch` temporal fija el provider (token de cuenta → `deepseek-account`) y el modelo |
| Los tokens de razonamiento van por stderr como `dsh: reasoning:` | se descartan; solo se conservan las líneas `dsh: <CODE>: <message>` |
| Las solicitudes de aprobación headless no tienen quién responda y fallan cerradas | los modos por defecto `workspace-write` y `--read-only` nunca usan `danger-full-access` |
| Un delegado puede hacer commit, cambiar de rama o stash pese al prompt | el forwarder compara los metadatos de git antes y después e imprime una línea `WARNING` por cada cambio |
| El loader YAML de `--patch` evalúa tags `!!js` | `--model` solo acepta un slug simple (`[A-Za-z0-9._-]`, máx. 64); cualquier otra cosa sale con 64 |
| `final` repite el último bloque de texto | el filtro imprime `final` solo si difiere |
| Windows: la herramienta de shell falla con `SetNamedSecurityInfoW failed (Win32 5): grantWrite(<workspace>)` aunque las ediciones de archivos funcionen. El sandbox se concede acceso al workspace y necesita que tu usuario tenga una entrada **explícita** de control total; los derechos de dueño solos (típico en carpetas fuera del perfil, como `C:\proyectos`) no bastan | arreglo único por árbol: `icacls C:\proyectos /grant <tu-usuario>:(OI)(CI)F` (deshacer: `icacls C:\proyectos /remove:g <tu-usuario>`) |
| Windows: dentro del sandbox los programas MSYS2 (Git Bash, `sed`, `grep`…) mueren al arrancar con `0xC0000022` | el delegado usa PowerShell; las herramientas nativas (`git`, `node`, `python`, `dotnet`) funcionan. Pide comandos de PowerShell en tareas que deban correr scripts |

## Qué hay en el plugin

| Pieza | Propósito |
|---|---|
| `agents/deepseek-rescue.md` | Subagente forwarder delgado — llamadas `preflight`, `start` y `wait`, salida devuelta tal cual |
| `scripts/deepseek-forward.sh` | Descubrimiento del launcher, preflight de provider/modelo, escritura del patch, jobs desacoplados, tramos de espera, cancelación, memoria de sesión, avisos de cambio de git |
| `scripts/stream-filter.js` | `--json` → log de progreso compacto |
| `tests/run.sh` | Tests herméticos con un `dsh` falso — `bash tests/run.sh` |
| `/deepseek:rescue` | Delega una tarea de forma explícita (`--background`, `--wait`, `--model`, `--read-only`, `--continue`) |
| `/deepseek:setup` | Localiza el CLI, versión, provider/inicio de sesión y cómo arreglar cada uno |
| `docs/claude-md-snippet.md` | Bloque de CLAUDE.md listo para pegar |
| `docs/delegation-guide.md` | Guía de orquestación multi-carril |

## Todavía no

- El layout de instalación de macOS no está verificado
  (`/Applications/DeepSeek Harness.app/...`); el forwarder lo intenta y luego
  cae a un `dsh` en el PATH.
- Una variante skill para Codex CLI (copilot-plugin-cc incluye una).
- Indicador de cuota: la facturación es el saldo de la plataforma DeepSeek, pero
  el CLI no expone un comando de uso headless que el forwarder pueda leer antes de
  una ejecución.

## Licencia

[MIT](LICENSE)
