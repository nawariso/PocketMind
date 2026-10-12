#!/usr/bin/env sh
# One command to provision PocketMind on Linux or macOS:  ./scripts/provision.sh --AdminEmail you@example.com
# It only makes sure PowerShell 7 exists, then hands over to scripts/provision.ps1, which checks the host and runs
# every step in the right order. Options are the parameters of provision.ps1, for example -CheckOnly or -Profile cpu.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

if ! command -v pwsh >/dev/null 2>&1; then
    case "$(uname -s)" in
        Darwin) how="brew install powershell" ;;
        Linux)  how="see https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux" ;;
        *)      how="see https://learn.microsoft.com/powershell/scripting/install/installing-powershell" ;;
    esac
    echo "PowerShell 7 (pwsh) is required to run the PocketMind scripts and was not found." >&2
    echo "Install it first: $how" >&2
    exit 1
fi

# Accept GNU-style options ("--AdminEmail x", "--CheckOnly") as well as PowerShell's ("-AdminEmail x").
# Rebuild the argument list one element at a time so values with spaces stay intact.
count=$#
while [ "$count" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
        --*) set -- "$@" "-${arg#--}" ;;
        *)   set -- "$@" "$arg" ;;
    esac
    count=$((count - 1))
done
exec pwsh -NoProfile -File "$here/provision.ps1" "$@"
