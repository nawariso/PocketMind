#!/usr/bin/env sh
# One command to provision PocketMind on Linux or macOS:  ./scripts/provision.sh --AdminEmail you@example.com
# It only makes sure PowerShell 7 exists, then hands over to scripts/provision.ps1, which checks the host and runs
# every step in the right order. Options are the parameters of provision.ps1, for example -CheckOnly or -Profile cpu.
#
# --InstallPrerequisites also installs PowerShell 7 here when it is missing (Homebrew on macOS, Microsoft's apt or
# dnf repository on Ubuntu, Debian, and RHEL-family Linux) after showing the commands and asking, unless --Yes is given.
# It never upgrades something that is already installed, and it never installs Docker.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
manual_url="https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
# Tests point this at a sample file; it is /etc/os-release everywhere else.
os_release=${PROVISION_OS_RELEASE:-/etc/os-release}
pwsh_dirs=${PROVISION_PWSH_DIRS:-"/opt/homebrew/bin /usr/local/bin /usr/bin /opt/microsoft/powershell/7"}

# Accept GNU-style options ("--AdminEmail x", "--CheckOnly") as well as PowerShell's ("-AdminEmail x").
# Rebuild the argument list one element at a time so values with spaces stay intact.
install_prerequisites=0
assume_yes=0
check_only=0
count=$#
while [ "$count" -gt 0 ]; do
    arg=$1
    shift
    case "$arg" in
        --*) arg="-${arg#--}" ;;
    esac
    case "$arg" in
        -InstallPrerequisites|-installprerequisites) install_prerequisites=1 ;;
        -Yes|-yes) assume_yes=1 ;;
        -CheckOnly|-checkonly) check_only=1 ;;
    esac
    set -- "$@" "$arg"
    count=$((count - 1))
done

# --- PowerShell installation -------------------------------------------------------------------------------------

confirm() {
    # Show the plan and ask. Without --Yes a terminal is required. With --CheckOnly nothing is installed.
    if [ "$check_only" -eq 1 ]; then
        printf '%s\n' "Check only: PowerShell would be installed with:"
        printf '  - %s\n' "$@"
        echo "Nothing was installed. The host checks need PowerShell, so run again without --CheckOnly to install it." >&2
        return 1
    fi
    printf '%s\n' "About to do:"
    printf '  - %s\n' "$@"
    if [ "$assume_yes" -eq 1 ]; then return 0; fi
    # /dev/tty can exist and still not be usable (no controlling terminal), so try to open it.
    if ! (: < /dev/tty) 2>/dev/null; then
        echo "Installing needs confirmation but there is no terminal; run again with --Yes to confirm." >&2
        return 1
    fi
    printf 'Proceed? (y/N) ' > /dev/tty
    read -r answer < /dev/tty
    case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

need_root_tools() {
    if [ "$(id -u)" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Installing needs root, and sudo was not found. Run as root, or install PowerShell yourself: $manual_url" >&2
            return 1
        fi
        # Ask for the password now rather than half way through.
        sudo -v
    fi
}

url_exists() {
    # True when the URL answers 200 (the repository publishes this distribution and version).
    if command -v curl >/dev/null 2>&1; then curl -fsSLI "$1" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then wget -q --spider "$1" >/dev/null 2>&1
    else return 2
    fi
}

install_pwsh_macos() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew was not found. Install it (https://brew.sh) or install PowerShell yourself: $manual_url" >&2
        return 1
    fi
    confirm "brew install powershell   (HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1: nothing already installed is upgraded)" || return 1
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install powershell
}

install_pwsh_linux() {
    if [ ! -r "$os_release" ]; then
        echo "Cannot tell which Linux this is (no /etc/os-release). Install PowerShell yourself: $manual_url" >&2
        return 1
    fi
    # shellcheck disable=SC1090
    . "$os_release"
    id_like=" ${ID_LIKE:-} "
    family=""
    case "${ID:-}" in
        ubuntu|debian) family=apt ;;
        rhel|rocky|almalinux|centos|ol) family=dnf ;;
        *) case "$id_like" in *" rhel "*|*" centos "*) family=dnf ;; esac ;;
    esac
    version_id=${VERSION_ID:-}
    if [ -z "$family" ] || [ -z "$version_id" ]; then
        echo "This Linux (${ID:-unknown} ${version_id:-}) is not covered by the automatic install. Install PowerShell yourself: $manual_url" >&2
        return 1
    fi

    if [ "$family" = apt ]; then
        repo_url="https://packages.microsoft.com/config/$ID/$version_id/packages-microsoft-prod.deb"
        confirm "apt-get install -y curl ca-certificates   (only if missing)" \
            "download $repo_url and install it with dpkg (adds Microsoft's package repository; used only when Microsoft publishes it for $ID $version_id)" \
            "apt-get update, then apt-get install -y powershell" || return 1
        need_root_tools || return 1
        export DEBIAN_FRONTEND=noninteractive
        as_root apt-get update
        as_root apt-get install -y curl ca-certificates
        if ! url_exists "$repo_url"; then
            echo "Microsoft's repository does not publish packages for $ID $version_id (or is unreachable). Install PowerShell yourself: $manual_url" >&2
            return 1
        fi
        tmp=$(mktemp)
        curl -fsSL "$repo_url" -o "$tmp"
        as_root dpkg -i "$tmp"
        rm -f "$tmp"
        as_root apt-get update
        as_root apt-get install -y powershell
    else
        major=${version_id%%.*}
        repo_url="https://packages.microsoft.com/config/rhel/$major/packages-microsoft-prod.rpm"
        confirm "dnf install -y $repo_url   (adds Microsoft's package repository)" "dnf install -y powershell" || return 1
        need_root_tools || return 1
        pkg=dnf
        command -v dnf >/dev/null 2>&1 || pkg=yum
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
            as_root "$pkg" install -y curl ca-certificates
        fi
        if ! url_exists "$repo_url"; then
            echo "Microsoft's repository does not publish packages for $ID $version_id (or is unreachable). Install PowerShell yourself: $manual_url" >&2
            return 1
        fi
        as_root "$pkg" install -y "$repo_url"
        as_root "$pkg" install -y powershell
    fi
}

find_pwsh() {
    hash -r 2>/dev/null || true
    if command -v pwsh >/dev/null 2>&1; then return 0; fi
    # A non-login shell may not have Homebrew's directory on PATH.
    for dir in $pwsh_dirs; do
        if [ -x "$dir/pwsh" ]; then PATH="$dir:$PATH"; export PATH; return 0; fi
    done
    return 1
}

if ! command -v pwsh >/dev/null 2>&1; then
    if [ "$install_prerequisites" -eq 1 ]; then
        case "$(uname -s)" in
            Darwin) install_pwsh_macos || exit 1 ;;
            Linux)  install_pwsh_linux || exit 1 ;;
            *)      echo "This operating system is not covered by the automatic install: $manual_url" >&2; exit 1 ;;
        esac
        if ! find_pwsh; then
            echo "PowerShell was installed but pwsh is still not on PATH; open a new shell and run this again." >&2
            exit 1
        fi
        echo "PowerShell installed: $(pwsh --version)"
    else
        case "$(uname -s)" in
            Darwin) how="brew install powershell" ;;
            Linux)  how="see ${manual_url}-on-linux" ;;
            *)      how="see $manual_url" ;;
        esac
        echo "PowerShell 7 (pwsh) is required to run the PocketMind scripts and was not found." >&2
        echo "Install it first: $how" >&2
        echo "Or run this script again with --InstallPrerequisites to have it installed for you." >&2
        exit 1
    fi
fi

exec pwsh -NoProfile -File "$here/provision.ps1" "$@"
