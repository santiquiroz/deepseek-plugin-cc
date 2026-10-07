# deepseek-plugin-cc

Delega tareas de código desde [Claude Code](https://claude.com/claude-code) a
la CLI de [DeepSeek Harness](https://www.deepseek.com/) (`dsh`) en modo headless.

Claude Code sigue siendo el orquestador — escribe la lógica de dominio, define
el contrato de cada subtarea y revisa los diffs. El delegado lee y edita archivos
y ejecuta comandos en tu repositorio, bajo un sandbox a nivel de SO confinado
al directorio de trabajo, y `--read-only` rechaza ediciones para revisiones y
diagnósticos que no deben tocar el árbol de trabajo. `deepseek-flash` cubre
trabajo mecánico y `deepseek-v4-pro` cubre trabajo de razonamiento; la
facturación es el saldo de tu plataforma DeepSeek (pago por uso).

> Read this in English: [README.md](README.md)

## Cuándo conviene

- **Dos modelos para dos tipos de trabajo.** `deepseek-flash` (por defecto)
  para tareas mecánicas — boilerplate, renombres, un archivo de spec, un build
  fix — y `deepseek-v4-pro` (vía `--model`) para tareas de razonamiento —
  diagnóstico, código cercano a arquitectura.
- **Un delegado que trabaja en tu repo.** La ejecución edita archivos y corre
  comandos en el propio directorio de trabajo, confinada por un sandbox a nivel
  de SO; las escrituras fuera del workspace fallan cerradas. Para revisiones y
  segundas opiniones que no deben tocar el árbol, `--read-only` rechaza
  ediciones.
- **Pago por uso.** Cada ejecución se cobra contra tu saldo de
  platform.deepseek.com, así que vigílalo: el CLI no expone un comando de uso
  headless que el forwarder pueda leer antes de una ejecución.

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

## Configuración inicial

Luego, una vez por máquina:

```
/deepseek:setup
```

Setup localiza el CLI, comprueba la versión y el provider/inicio de sesión, y te
dice cómo arreglar cada uno cuando falta.

- **Inicio de sesión.** Abre DeepSeek Harness e inicia sesión una vez: el token
  de cuenta se lee de `${DSH_HOME:-$HOME/.dsh}/.credentials.yaml` y la ejecución
  usa el provider `deepseek-account`. Sin sesión iniciada, exporta
  `DEEPSEEK_API_KEY` para usar el provider `deepseek-official`. Sin ninguno de
  los dos, `preflight` falla con exit 70.
- **Acceso al workspace en Windows.** Si los comandos de shell en el sandbox
  fallan con `SetNamedSecurityInfoW failed (Win32 5): grantWrite(<workspace>)`,
  tu usuario necesita una entrada **explícita** de control total sobre el
  workspace — los derechos de dueño solos (típico en carpetas fuera del perfil,
  como `C:\proyectos`) no bastan. Arreglo único por árbol:
  `icacls C:\proyectos /grant <tu-usuario>:(OI)(CI)F`
  (deshacer: `icacls C:\proyectos /remove:g <tu-usuario>`).

## Uso

```
/deepseek:rescue add unit tests for src/utils/money.ts covering rounding and negative amounts (signatures pasted below) ...
/deepseek:rescue --background rename UserDto to UserResponse across src/api and update the imports
/deepseek:rescue --read-only review src/services/billing.ts for race conditions; report only
/deepseek:rescue --model deepseek-v4-pro diagnose this build failure across the module graph ...
```

### Flags

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

### Ejecuciones largas

Las ejecuciones duran hasta `DEEPSEEK_RESCUE_MAX_SECONDS` (por defecto 2700
segundos, 45 minutos). `start` desacopla el job y `wait` lo espera en tramos de
480 segundos (máximo 540; `--slice <segundos>` cambia la duración del tramo),
cada uno en una llamada Bash foreground separada con timeout 600000 ms, nunca
`run_in_background`. El presupuesto es `1 + 1 + ceil(MAX/480) + 1` llamadas.
El tope anterior de 9 minutos (`timeout -k 10 540`) dejaba margen bajo el techo
de 600 segundos de Bash; `run` conserva ese tope como vía corta. El subagente
pide `--json` e imprime solo el progreso nuevo de cada tramo — texto del
asistente, una línea por llamada a herramienta, una línea por denegación. Un
`wait` pasado el plazo mata el árbol de procesos con exit 124; `cancel <id>`
lo hace con exit 130. Las ediciones hechas hasta entonces quedan en tu árbol de
trabajo. Si el subagente se interrumpe, el job desacoplado sigue corriendo:
conserva su id para esperar o cancelarlo después.

### Delegación proactiva

La descripción del agente `deepseek-rescue` le dice a Claude Code que lo use por
su cuenta. Esa ejecución envía el texto de la tarea al backend de DeepSeek y deja
que el modelo edite archivos en el repositorio actual dentro de un sandbox
confinado al espacio de trabajo. Lo que se interpone entre eso y tu árbol de
trabajo es el sistema de permisos propio de Claude Code: la única herramienta
del subagente es `Bash`, así que en el modo de permisos por defecto apruebas el
comando de lanzamiento antes de que corra, mientras que bajo bypass mode corre
sin preguntar. Si quieres delegación solo bajo pedido, agrega esta línea a
`~/.claude/CLAUDE.md`:

```
Never launch deepseek:deepseek-rescue on your own; use it only when I invoke /deepseek:rescue explicitly.
```

### Qué ejecuta realmente el forwarder

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

## Configuración

Todas las variables siguientes las lee `scripts/deepseek-forward.sh`:

- `DEEPSEEK_RESCUE_MAX_SECONDS` (por defecto `2700`) — plazo de un job lanzado
  con `start`, esperado mediante tramos `wait`.
- `DEEPSEEK_RESCUE_TIMEOUT` (por defecto `540`) — tope de la vía corta `run`.
- `DEEPSEEK_RESCUE_HOME` (por defecto `$HOME/.deepseek-rescue`) — jobs
  desacoplados en `jobs/<id>/`, sesiones recordadas en
  `sessions/<sha1 de $PWD>`.
- `DEEPSEEK_API_KEY` — API key para el provider `deepseek-official` cuando la
  app de escritorio no tiene sesión iniciada.
- `DSH_HOME` (por defecto `$HOME/.dsh`) — ubicación del token de cuenta
  (`.credentials.yaml`) para el provider `deepseek-account`.
- `DSH_BIN` — usa este binario `dsh` en lugar de la app instalada.
- `DSH_PERMISSION_MODE` — lo gestiona el forwarder (`workspace-write`, o
  `read-only` con `--read-only`); `danger-full-access` se rechaza con exit 64.

## Solución de problemas

Todas las entradas siguientes están verificadas contra DeepSeek Harness
0.2.0-rc.2 (Windows 11).

| Síntoma | Manejo |
|---|---|
| `dsh not found` (exit 127) | instala la app de escritorio de DeepSeek Harness (o define `DSH_BIN`), luego corre `/deepseek:setup` de nuevo |
| Sin credenciales (exit 70) / `MISSING_CREDENTIAL` | abre DeepSeek Harness e inicia sesión una vez (token de cuenta), o exporta `DEEPSEEK_API_KEY`, luego corre `/deepseek:setup` de nuevo |
| La salida menciona `Insufficient Balance`, `402`, `rate limit`, `429`, `quota`, `MISSING_CREDENTIAL`, `401` o `Authentication` | la ejecución se detiene con `[deepseek-rescue] DeepSeek balance or rate limit hit`; nunca se reintenta — la tarea necesita otra vía |
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
| El layout de instalación de macOS no está verificado (`/Applications/DeepSeek Harness.app/...`) | el forwarder lo intenta y luego cae a un `dsh` en el PATH |

## Con otros delegados

Este plugin no asume ningún orden frente a otros delegados: solo reenvía tareas
a `dsh` e informa el resultado. Si corres varios delegados, el orden, los
disparadores y el reparto del trabajo los decides tú en tu propio `CLAUDE.md`.

Proyectos relacionados, sin ningún orden en particular: [copilot-plugin-cc](https://github.com/santiquiroz/copilot-plugin-cc), [antigravity-plugin-cc](https://github.com/santiquiroz/antigravity-plugin-cc), [ollama-plugin-cc](https://github.com/santiquiroz/ollama-plugin-cc), [cursor-plugin-cc](https://github.com/santiquiroz/cursor-plugin-cc) y [bipolar-plugin-cc](https://github.com/santiquiroz/bipolar-plugin-cc), todos inspirados en la estructura de [openai/codex-plugin-cc](https://github.com/openai/codex-plugin-cc).

## Licencia

[MIT](LICENSE)

**No está afiliado con DeepSeek, OpenAI, GitHub, Google ni Anthropic.**
