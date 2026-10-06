// Turns `dsh --json` into a compact progress log, line by line, so a run cut by the timeout still
// shows what it did. Session id and token totals are written to $DSH_RESCUE_META_FILE for the
// forwarder to remember the session. Non-JSON stdout lines pass through.
const fs = require("fs");
const readline = require("readline");

const NOISE = /^(Connection lost|Retry attempt)/;

const callTool = Object.create(null);
let sessionId = "";
let tokensIn = 0;
let tokensOut = 0;
let lastText = "";

function loadState() {
  const path = process.env.DSH_RESCUE_STATE_FILE;
  if (!path || !fs.existsSync(path)) return;
  const state = JSON.parse(fs.readFileSync(path, "utf8"));
  sessionId = state.sessionId || "";
  tokensIn = state.tokensIn || 0;
  tokensOut = state.tokensOut || 0;
  lastText = state.lastText || "";
  Object.assign(callTool, state.callTool || {});
}

function writeState() {
  const path = process.env.DSH_RESCUE_STATE_FILE;
  if (!path) return;
  const offsetPath = process.env.DSH_RESCUE_OFFSET_FILE;
  const rawOffset = offsetPath ? Number(fs.readFileSync(offsetPath + ".pending", "utf8")) : undefined;
  fs.writeFileSync(path + ".tmp", JSON.stringify({ sessionId, tokensIn, tokensOut, lastText, callTool, rawOffset }));
  fs.renameSync(path + ".tmp", path);
  if (offsetPath) fs.writeFileSync(offsetPath, String(rawOffset) + "\n");
}

function readSlice(path, offsetPath, final) {
  const offset = sliceOffset(offsetPath);
  const fd = fs.openSync(path, "r");
  const bytes = Buffer.alloc(Math.max(0, fs.fstatSync(fd).size - offset));
  const count = fs.readSync(fd, bytes, 0, bytes.length, offset);
  fs.closeSync(fd);
  const available = bytes.subarray(0, count);
  const consumed = final ? count : available.lastIndexOf(10) + 1;
  fs.writeFileSync(offsetPath + ".pending", String(offset + consumed) + "\n");
  if (!consumed) return;
  process.stdout.write(available.subarray(0, consumed));
  if (final && available[consumed - 1] !== 10) process.stdout.write("\n");
}

function sliceOffset(offsetPath) {
  const statePath = process.env.DSH_RESCUE_STATE_FILE;
  if (statePath && fs.existsSync(statePath)) {
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
    if (Number.isSafeInteger(state.rawOffset)) return state.rawOffset;
  }
  return Number(fs.readFileSync(offsetPath, "utf8")) || 0;
}

function oneLine(value, max) {
  const text = String(value == null ? "" : value).replace(/\s+/g, " ").trim();
  return text.length > max ? text.slice(0, max) + "..." : text;
}

function targetOf(input) {
  if (!input || typeof input !== "object") return "";
  return input.file_path || input.path || input.command || input.pattern
    || Object.values(input).find((value) => typeof value === "string") || "";
}

function statusLine(event) {
  if (event.phase === "step_end") {
    const usage = event.usage || {};
    tokensIn += Number(usage.inputTokens) || 0;
    tokensOut += Number(usage.outputTokens) || 0;
  }
  return "";
}

function toolCallLine(event) {
  const tool = event.tool || "tool";
  if (event.callId) callTool[event.callId] = tool;
  return "  > " + tool + " " + oneLine(targetOf(event.input), 120);
}

function toolResultLine(event) {
  if (event.status !== "error") return "";
  const tool = (event.callId && callTool[event.callId]) || "tool";
  const firstLine = String(event.result == null ? "" : event.result).split("\n")[0];
  return "  x " + tool + ": " + oneLine(firstLine, 220);
}

function render(line) {
  let event;
  try {
    event = JSON.parse(line);
  } catch (e) {
    return line.trim() && !NOISE.test(line) ? line : "";
  }
  if (!event || typeof event !== "object") return "";
  switch (event.type) {
    case "session":
      sessionId = event.sessionId || "";
      return "";
    case "status":
      return statusLine(event);
    case "thinking":
      return ""; // reasoning is also streamed on stderr as `dsh: reasoning:`; drop both
    case "text":
      lastText = event.text || "";
      return lastText;
    case "final":
      return event.text && event.text !== lastText ? event.text : ""; // final repeats the last text block
    case "tool_call":
      return toolCallLine(event);
    case "tool_result":
      return toolResultLine(event);
    case "error":
      return oneLine(event.message || JSON.stringify(event), 220);
    default:
      return "";
  }
}

function writeMeta() {
  const path = process.env.DSH_RESCUE_META_FILE;
  if (!path) return;
  try {
    fs.writeFileSync(path, [sessionId, tokensIn, tokensOut].join("\n") + "\n");
  } catch (e) {
    // best-effort: the forwarder still prints the log and the run result
  }
}

function filterStream() {
  loadState();
  readline.createInterface({ input: process.stdin })
    .on("line", (line) => {
      const out = render(line);
      if (out) console.log(out);
    })
    .on("close", () => {
      writeState();
      writeMeta();
    });
}

if (process.argv[2] === "--read-slice") {
  readSlice(process.argv[3], process.argv[4], process.argv[5] === "final");
} else {
  filterStream();
}
