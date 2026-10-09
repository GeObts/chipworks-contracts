# shellcheck shell=bash
# Source this from any tool that calls `cast`:   . "$(dirname "$0")/lib/find-cast.sh"
#
# Makes `cast` work whichever shell launched the script — Git Bash, WSL bash, or bash started
# from PowerShell — even when Foundry's folder is not on that shell's PATH (the usual Windows
# case: cast.exe is only on PowerShell's PATH). Order: $CAST (explicit override), then under
# WSL the Windows cast.exe (where the keystores are), `cast` on PATH, ~/.foundry/bin, then the
# Windows install as Git Bash and WSL each see it.
#
# Defines a `cast` FUNCTION, so every existing `cast …` line keeps working unchanged. It strips
# CR from cast.exe's output (Windows line endings would break `awk`/`-ge` parsing) and keeps
# cast's own exit status. Keystore passwords: pass `--password-file` explicitly (in cast 1.7.1
# the ETH_PASSWORD env var is a password FILE path, not the password).

__find_cast() {
  local c wsl_win=""
  # Under WSL, prefer the WINDOWS cast.exe: the keystores (chipworks-deployer) live in the
  # Windows ~/.foundry, and a Linux cast inside WSL would look in WSL's own ~/.foundry instead.
  if grep -qi microsoft /proc/version 2>/dev/null; then wsl_win="/mnt/c/Users/1136962520/.foundry/bin/cast.exe"; fi
  for c in \
    "${CAST:-}" \
    "$wsl_win" \
    "$(command -v cast 2>/dev/null || true)" \
    "$HOME/.foundry/bin/cast" \
    "$HOME/.foundry/bin/cast.exe" \
    "/c/Users/1136962520/.foundry/bin/cast.exe" \
    "/mnt/c/Users/1136962520/.foundry/bin/cast.exe" \
    "C:/Users/1136962520/.foundry/bin/cast.exe"; do
    if [ -n "$c" ] && [ -f "$c" ] && [ "$(type -t "$c" 2>/dev/null)" != "function" ]; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}

if ! CAST_BIN=$(__find_cast); then
  echo "ERROR: Foundry's cast was not found (looked on PATH, in ~/.foundry/bin and in" >&2
  echo "C:\\Users\\1136962520\\.foundry\\bin). Set CAST=/path/to/cast.exe and re-run." >&2
  exit 127
fi
export CAST_BIN

cast() {
  local rc
  "$CAST_BIN" "$@" | tr -d '\r'
  rc=${PIPESTATUS[0]}
  return "$rc"
}
