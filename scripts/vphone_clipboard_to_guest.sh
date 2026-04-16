#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:a:h}"
ROOT_DIR="${SCRIPT_DIR:h}"

socket_path=""
vm_dir="${ROOT_DIR}/vm"
text_mode="pbpaste"
text_arg=""

usage() {
  cat <<'EOF'
Usage: scripts/vphone_clipboard_to_guest.sh [--vm-dir DIR] [--socket PATH] [--text TEXT | --stdin]

Copies UTF-8 text from macOS into the running vphone guest clipboard.

Defaults:
  - Reads host clipboard via pbpaste
  - Connects to <vm-dir>/.vphone-clipboard.sock

Examples:
  scripts/vphone_clipboard_to_guest.sh
  scripts/vphone_clipboard_to_guest.sh --vm-dir ./vm-ios18
  scripts/vphone_clipboard_to_guest.sh --text 'hello 你好'
  printf 'line1\nline2\n中文\n' | scripts/vphone_clipboard_to_guest.sh --stdin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-dir)
      [[ $# -ge 2 ]] || { echo "error: --vm-dir requires a value" >&2; exit 1; }
      vm_dir="$2"
      shift 2
      ;;
    --socket)
      [[ $# -ge 2 ]] || { echo "error: --socket requires a value" >&2; exit 1; }
      socket_path="$2"
      shift 2
      ;;
    --text)
      [[ $# -ge 2 ]] || { echo "error: --text requires a value" >&2; exit 1; }
      text_mode="arg"
      text_arg="$2"
      shift 2
      ;;
    --stdin)
      text_mode="stdin"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${socket_path}" ]]; then
  socket_path="${vm_dir:A}/.vphone-clipboard.sock"
fi

if [[ ! -S "${socket_path}" ]]; then
  echo "error: clipboard bridge socket not found: ${socket_path}" >&2
  echo "hint: boot vphone first, then rerun this script." >&2
  exit 1
fi

payload_file="$(mktemp -t vphone-clipboard.XXXXXX)"
cleanup() {
  rm -f "${payload_file}"
}
trap cleanup EXIT

case "${text_mode}" in
  pbpaste)
    pbpaste > "${payload_file}"
    ;;
  arg)
    printf '%s' "${text_arg}" > "${payload_file}"
    ;;
  stdin)
    cat > "${payload_file}"
    ;;
esac

/usr/bin/python3 - "${socket_path}" "${payload_file}" <<'PY'
import base64
import json
import socket
import sys

socket_path = sys.argv[1]
payload_path = sys.argv[2]

with open(payload_path, "rb") as fh:
    payload = fh.read()

request = json.dumps(
    {"textBase64": base64.b64encode(payload).decode("ascii")},
    separators=(",", ":"),
).encode("utf-8")

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    client.connect(socket_path)
    client.sendall(request)
    client.shutdown(socket.SHUT_WR)

    response = bytearray()
    while True:
        chunk = client.recv(8192)
        if not chunk:
            break
        response.extend(chunk)
finally:
    client.close()

if not response:
    print("error: no response from clipboard bridge", file=sys.stderr)
    sys.exit(1)

decoded = json.loads(response.decode("utf-8"))
if not decoded.get("ok"):
    print(f"error: {decoded.get('message', 'clipboard update failed')}", file=sys.stderr)
    sys.exit(1)

size = decoded.get("bytes")
if size is None:
    print(decoded.get("message", "guest clipboard updated"))
else:
    print(f"{decoded.get('message', 'guest clipboard updated')} ({size} bytes)")
PY
