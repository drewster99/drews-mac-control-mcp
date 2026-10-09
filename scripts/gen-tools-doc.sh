#!/bin/bash
#
# gen-tools-doc.sh — regenerate docs/MCP_TOOLS.md from the server's own `initialize` and
# `tools/list` output.
#
# The reference doc is generated rather than written because hand edits drifted: it sat at 0.2.26
# for months while tools gained parameters, lost them, and changed their descriptions.
# ToolNameDriftTests fails when the doc and the live descriptors disagree; run this to fix it.
#
# Only the "All tools" table, the per-tool sections, the version stamps and the server
# instructions are rewritten. The hand-written prose above "## All tools" is kept. Parameter rows
# keep the order the doc already has, so a regeneration diff shows only real changes.
#
# Usage:
#   ./scripts/gen-tools-doc.sh [path/to/MacControlStdio]
#
# With no argument, uses the Debug MacControlStdio from this project's DerivedData (build the
# `All` scheme first). Listing tools calls no tool, so this needs no grants and changes nothing.
#
set -euo pipefail
cd "$(dirname "$0")/.."

STDIO="${1:-}"
if [ -z "$STDIO" ]; then
  candidates=()
  for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/MacControlMCP-*/Build/Products/Debug/MacControlStdio; do
    [ -x "$candidate" ] && candidates+=("$candidate")
  done
  if [ "${#candidates[@]}" -ne 1 ]; then
    echo "gen-tools-doc: expected exactly one Debug MacControlStdio in DerivedData, found ${#candidates[@]}." >&2
    echo "  Build the All scheme, or pass the binary's path." >&2
    exit 1
  fi
  STDIO="${candidates[0]}"
fi
[ -x "$STDIO" ] || { echo "gen-tools-doc: not executable: $STDIO" >&2; exit 1; }

LIVE="$(mktemp)"
trap 'rm -f "$LIVE"' EXIT
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"gen-tools-doc","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | "$STDIO" > "$LIVE"

python3 -I - "$LIVE" docs/MCP_TOOLS.md <<'PY'
import json, re, sys, pathlib

live_path, doc_path = sys.argv[1], sys.argv[2]
responses = {r["id"]: r for r in (json.loads(line) for line in open(live_path) if line.strip())}
if 1 not in responses or 2 not in responses:
    sys.exit("gen-tools-doc: the server did not answer both initialize and tools/list")
init, tools = responses[1]["result"], responses[2]["result"]["tools"]
version = init["serverInfo"]["version"]
doc = pathlib.Path(doc_path).read_text()

old_order = {}
for match in re.finditer(r"^### `([a-z_]+)`\n(.*?)(?=^### |\Z)", doc, re.M | re.S):
    old_order[match.group(1)] = re.findall(r"^\| `([A-Za-z_]+)` \|", match.group(2), re.M)

def cell(text):
    """One line, with `|` escaped so a description cannot split a Markdown table row."""
    return " ".join(text.split()).replace("|", "\\|")

def type_of(prop):
    kind = prop.get("type", "")
    if isinstance(kind, list):
        kind = "/".join(kind)
    if "enum" in prop:
        kind += " (" + ", ".join(str(e) for e in prop["enum"]) + ")"
    return cell(kind)

def replace_once(pattern, replacement, text, what, flags=0):
    result, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        sys.exit(f"gen-tools-doc: could not find the {what} in {doc_path}")
    return result

head = doc[:doc.index("## All tools")]
head = replace_once(r"v\d+\.\d+\.\d+ · MCP protocol [0-9-]+",
                    f"v{version} · MCP protocol {init['protocolVersion']}", head, "header version stamp")
head = replace_once(r"`version=\d+\.\d+\.\d+`", f"`version={version}`", head, "serverInfo version")
instructions = init.get("instructions")
paragraph = ("The MCP `initialize` response carries a top-level `instructions` string, which a client shows "
             "its model before any tool call:\n\n> " + " ".join(instructions.split()) + "\n\n"
             if instructions else
             "The MCP `initialize` response carries no top-level `instructions` string.\n\n")
paragraph += "The rest of the client-facing guidance lives in the per-tool `description` fields below."
head = replace_once(r"The MCP `initialize` response.*?`description` fields below\.",
                    lambda _: paragraph, head, "server instructions paragraph", re.S)

out = [head + "## All tools\n", "| # | Tool | Description |", "|---|------|-------------|"]
for number, tool in enumerate(tools, 1):
    out.append(f"| {number} | `{tool['name']}` | {cell(tool['description'])} |")
out += ["", "## Parameters by tool", ""]
for tool in tools:
    schema = tool.get("inputSchema", {})
    props, required = schema.get("properties", {}), set(schema.get("required", []))
    out += [f"### `{tool['name']}`", "", cell(tool["description"]), ""]
    if not props:
        out += ["_No parameters._", ""]
        continue
    kept = [name for name in old_order.get(tool["name"], []) if name in props]
    names = kept + sorted(name for name in props if name not in kept)
    out += ["| Parameter | Type | Required | Description |", "|-----------|------|----------|-------------|"]
    for name in names:
        prop = props[name]
        out.append(f"| `{name}` | {type_of(prop)} | {'yes' if name in required else 'no'} | "
                   f"{cell(prop.get('description', ''))} |")
    out.append("")
pathlib.Path(doc_path).write_text("\n".join(out).rstrip("\n") + "\n")
print(f"docs/MCP_TOOLS.md regenerated: {len(tools)} tools, server v{version}")
PY
