#!/usr/bin/env sh
# Logic test of the PowerShell installer in scripts/provision.sh, with stand-in programs for apt-get, dpkg, dnf,
# brew, curl, sudo, id, and uname placed first on PATH. It proves which commands run, in which order, for which
# distribution, and when the script refuses. It does NOT install anything and so does not prove that Microsoft's
# repositories or the package managers work; that needs a host with unrestricted network access.
set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
shell_bin=$(command -v sh)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
checks=0
failures=0

pass() { checks=$((checks + 1)); }
fail() {
    checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL: $1"
    if [ -n "${HARNESS_VERBOSE:-}" ]; then
        echo "  exit status: ${rc:-?}"; echo "  stdout:"; sed 's/^/    /' "$work/out" 2>/dev/null; echo "  stderr:"; sed 's/^/    /' "$work/err" 2>/dev/null; echo "  log:"; sed 's/^/    /' "$log" 2>/dev/null
    fi
}
expect() { if eval "$2"; then pass; else fail "$1"; fi; }

# A fresh set of stand-ins. $1 = uname, $2 = uid, $3 = "sudo" to provide sudo, $4 = URL fragment that curl must refuse
new_world() {
    refuse_pattern=${4:-@@never@@}
    stubs="$work/stubs"; rm -rf "$stubs"; mkdir -p "$stubs"
    log="$work/log"; : > "$log"
    for tool in dirname mktemp rm cat chmod; do ln -s "$(command -v "$tool")" "$stubs/$tool"; done
    printf '#!/bin/sh\necho %s\n' "$1" > "$stubs/uname"
    printf '#!/bin/sh\necho %s\n' "$2" > "$stubs/id"
    if [ "$3" = sudo ]; then
        printf '#!/bin/sh\necho "sudo $*" >> "%s"\n[ "$1" = "-v" ] && exit 0\nexec "$@"\n' "$log" > "$stubs/sudo"
    fi
    printf '#!/bin/sh\necho "curl $*" >> "%s"\ncase " $* " in *" -I "*|*" -fsSLI "*) case "$*" in *"%s"*) exit 22 ;; esac; exit 0 ;; esac\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && : > "$2"; shift; done\nexit 0\n' "$log" "$refuse_pattern" > "$stubs/curl"
    for tool in apt-get dnf dpkg; do
        printf '#!/bin/sh\necho "%s $* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >> "%s"\n' "$tool" "$log" > "$stubs/$tool"
    done
    # Installing the "powershell" package leaves a pwsh behind, like the real package does.
    for tool in apt-get dnf; do
        printf '#!/bin/sh\necho "%s $* [DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-}]" >> "%s"\ncase "$*" in *"install -y powershell"*) [ -z "${NO_PWSH_INSTALLED:-}" ] && printf "#!/bin/sh\\necho \\"pwsh \\$*\\" >> \\"%s\\"\\n[ \\"\\$1\\" = --version ] && echo PowerShell-7-stub\\nexit 0\\n" > "%s/pwsh" && chmod +x "%s/pwsh" ;; esac\nexit 0\n' "$tool" "$log" "$log" "$stubs" "$stubs" > "$stubs/$tool"
    done
    printf '#!/bin/sh\necho "brew $* [NO_AUTO_UPDATE=${HOMEBREW_NO_AUTO_UPDATE:-} NO_INSTALL_UPGRADE=${HOMEBREW_NO_INSTALL_UPGRADE:-}]" >> "%s"\nprintf "#!/bin/sh\\necho \\"pwsh \\$*\\" >> \\"%s\\"\\n[ \\"\\$1\\" = --version ] && echo PowerShell-7-stub\\nexit 0\\n" > "%s/pwsh"; chmod +x "%s/pwsh"\n' "$log" "$log" "$stubs" "$stubs" > "$stubs/brew"
    chmod +x "$stubs"/*
}

os_release() {
    # $1 = ID, $2 = VERSION_ID, $3 = ID_LIKE
    printf 'ID=%s\nVERSION_ID="%s"\nID_LIKE="%s"\n' "$1" "$2" "$3" > "$work/os-release"
}

run() {
    # Runs provision.sh with only the stand-ins on PATH. Output goes to $work/out and $work/err, the status to $rc.
    PATH="$stubs" PROVISION_OS_RELEASE="$work/os-release" PROVISION_PWSH_DIRS="$work/no-such-dir" "$shell_bin" "$repo/scripts/provision.sh" "$@" > "$work/out" 2> "$work/err" < /dev/null
    rc=$?
}

in_order() {
    # True when every pattern appears in the log, in the given order.
    last=0
    for pattern in "$@"; do
        line=$(grep -n -F -- "$pattern" "$log" | head -1 | cut -d: -f1)
        [ -n "$line" ] && [ "$line" -gt "$last" ] || return 1
        last=$line
    done
    return 0
}

installs() { grep -cE '^(apt-get (update|install)|dnf install|dpkg -i|brew install)' "$log"; }

args="--AdminEmail a@b.c --InstallPrerequisites --Yes"

# 1. no flag: tells the user, installs nothing
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
run --AdminEmail a@b.c
expect "without the flag the script must fail" "[ $rc -eq 1 ]"
expect "without the flag it must mention --InstallPrerequisites" "grep -q -- '--InstallPrerequisites' '$work/err'"
expect "without the flag nothing is installed" "[ \"\$(installs)\" -eq 0 ]"

# 2. Ubuntu 24.04 as root
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
run $args
expect "ubuntu: succeeds and hands over to pwsh" "[ $rc -eq 0 ] && grep -q 'pwsh -NoProfile -File .*provision.ps1' '$log'"
expect "ubuntu: installs in order (curl, repo package, powershell)" "in_order 'apt-get update' 'apt-get install -y curl ca-certificates' 'curl -fsSLI https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb' 'curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb' 'dpkg -i' 'apt-get install -y powershell' 'pwsh -NoProfile -File'"
expect "ubuntu: apt runs non-interactively" "grep -q 'apt-get install -y powershell \[DEBIAN_FRONTEND=noninteractive\]' '$log'"
expect "ubuntu: arguments are forwarded with PowerShell-style flags" "grep -q 'pwsh .*-AdminEmail a@b.c -InstallPrerequisites -Yes' '$log'"
expect "ubuntu: no sudo is used as root" "! grep -q '^sudo' '$log'"

# 3. Debian 12
new_world Linux 0 none ""; os_release debian 12 ""
run $args
expect "debian: uses the debian/12 repository package" "[ $rc -eq 0 ] && grep -q 'config/debian/12/packages-microsoft-prod.deb' '$log'"

# 4. Rocky Linux 9.4 (RHEL family)
new_world Linux 0 none ""; os_release rocky 9.4 "rhel centos fedora"
run $args
expect "rocky: succeeds" "[ $rc -eq 0 ] && grep -q 'pwsh -NoProfile -File' '$log'"
expect "rocky: uses the rhel/9 repository package with dnf, in order" "in_order 'curl -fsSLI https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm' 'dnf install -y https://packages.microsoft.com/config/rhel/9/packages-microsoft-prod.rpm' 'dnf install -y powershell'"
expect "rocky: apt is not used" "! grep -q '^apt-get' '$log'"

# 5. a distribution that is not covered
new_world Linux 0 none ""; os_release alpine 3.20 ""
run $args
expect "unknown distro: refuses and gives the manual link" "[ $rc -eq 1 ] && grep -q 'not covered by the automatic install' '$work/err' && grep -q 'learn.microsoft.com' '$work/err'"
expect "unknown distro: installs nothing" "[ \"\$(installs)\" -eq 0 ]"

# 6. Microsoft publishes no package for this version: refuse instead of guessing
new_world Linux 0 none "ubuntu/26.99"; os_release ubuntu 26.99 debian
run $args
expect "unpublished version: refuses" "[ $rc -eq 1 ] && grep -q 'does not publish packages' '$work/err'"
expect "unpublished version: never installs the repository or powershell" "! grep -qE 'dpkg -i|install -y powershell' '$log'"

# 7. -CheckOnly: shows the plan, installs nothing
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
run --AdminEmail a@b.c --InstallPrerequisites --CheckOnly
expect "check only: refuses to install and shows the plan" "[ $rc -eq 1 ] && grep -q 'Check only: PowerShell would be installed' '$work/out'"
expect "check only: installs nothing" "[ \"\$(installs)\" -eq 0 ]"

# 8. no terminal and no --Yes (skipped when this shell has a usable terminal)
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
if (: < /dev/tty) 2>/dev/null; then
    echo "SKIP: this shell has a terminal, so the no-terminal refusal cannot be tested here"
else
    run --AdminEmail a@b.c --InstallPrerequisites
    expect "no terminal and no --Yes: refuses" "[ $rc -eq 1 ] && grep -q 'no terminal' '$work/err'"
    expect "no terminal and no --Yes: installs nothing" "[ \"\$(installs)\" -eq 0 ]"
fi

# 9. not root, no sudo
new_world Linux 501 none ""; os_release ubuntu 24.04 debian
run $args
expect "not root and no sudo: refuses" "[ $rc -eq 1 ] && grep -q 'sudo was not found' '$work/err'"
expect "not root and no sudo: installs nothing" "[ \"\$(installs)\" -eq 0 ]"

# 10. not root, with sudo: asks for the password first, then uses sudo for every install command
new_world Linux 501 sudo ""; os_release ubuntu 24.04 debian
run $args
expect "sudo: succeeds" "[ $rc -eq 0 ]"
expect "sudo: password is asked first, then root commands run through sudo" "in_order 'sudo -v' 'sudo apt-get update' 'sudo apt-get install -y curl ca-certificates' 'sudo dpkg -i' 'sudo apt-get install -y powershell'"

# 11. the package manager runs but pwsh still cannot be found
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
NO_PWSH_INSTALLED=1 run $args
expect "pwsh still missing after the install: says so" "[ $rc -eq 1 ] && grep -q 'still not on PATH' '$work/err'"

# 12. macOS: Homebrew is told not to update or upgrade anything
new_world Darwin 501 none ""
run $args
expect "macos: brew install powershell, then hand over" "[ $rc -eq 0 ] && in_order 'brew install powershell' 'pwsh -NoProfile -File'"
expect "macos: Homebrew is told never to auto-update or upgrade" "grep -q 'brew install powershell \[NO_AUTO_UPDATE=1 NO_INSTALL_UPGRADE=1\]' '$log'"
new_world Darwin 501 none ""; rm -f "$stubs/brew"
run $args
expect "macos without Homebrew: refuses with a pointer" "[ $rc -eq 1 ] && grep -q 'Homebrew was not found' '$work/err'"

# 13. pwsh already present: nothing is installed, even with the flag
new_world Linux 0 none ""; os_release ubuntu 24.04 debian
printf '#!/bin/sh\necho "pwsh $*" >> "%s"\nexit 0\n' "$log" > "$stubs/pwsh"; chmod +x "$stubs/pwsh"
run $args
expect "pwsh present: nothing is installed and the script hands over" "[ $rc -eq 0 ] && [ \"\$(installs)\" -eq 0 ] && grep -q 'pwsh -NoProfile -File' '$log'"

if [ "$failures" -gt 0 ]; then
    echo "provision.sh installer logic: $failures of $checks checks failed"
    exit 1
fi
echo "provision.sh installer logic: all $checks checks passed"
