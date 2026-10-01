#!/usr/bin/env bash
# SIFT Azure workstation setup, version 1.0.0.
# Run on a dedicated Ubuntu 24.04 x86_64 VM, not on Windows or in Azure Cloud Shell.
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi
set -Eeuo pipefail
umask 022

readonly SCRIPT_VERSION=1.0.0
readonly STATE=/var/lib/sift-azure-setup
readonly LOG=/var/log/sift-azure-setup.log
readonly UNIT=sift-azure-setup.service
readonly CAST_VERSION=v1.0.36
readonly CAST_SHA256=89d2ef4b55ebcef18835e37d3f06dee2f7eda525c383526bedfcb22c8fea7a8c
readonly SIFT_RELEASE=v2026.04.21
MODE=install
MODE_SET=0
YES=0
DESKTOP_USER=dfiradmin
USER_SET=0
PHASE=initialization
CAST_ATTEMPTED=0
FINISHED=0

usage() {
    cat <<'USAGE'
Usage: sudo bash setup-sift-azure.sh [--user LOCAL_USER] [MODE] [--yes]

Default: prepare the local account and start a persistent background installation.
  --user NAME    Local desktop account; default dfiradmin. Existing passwords remain unchanged.
  --dry-run      Check prerequisites and print the plan without changing the VM.
  --status       Show the recorded installer status and recent log messages.
  --verify       Check the installed workstation as the desktop user; no installation or reboot.
  --resume       Resume this script's failed/interrupted installation.
  --yes          Acknowledge backup and private-network prerequisites without a confirmation prompt.
  --help         Show this help.
  --version      Show this script's version.

Ubuntu 24.04 x86_64, systemd, root/sudo, Internet package access, and at least 60 GiB free
are required for installation. A 128 GiB persistent OS disk is recommended.
Before starting, take a backup and allow TCP 3389 ONLY from your Bastion/VPN management
network in Azure NSGs. This script does not configure Azure networking or enlarge disks.

New users, or users without a usable local password, require an interactive terminal
for passwd. For noninteractive execution, prepare the local account/password first.
No default password is created; no password argument or password file is accepted.

Monitor: sudo bash setup-sift-azure.sh --status
         sudo tail -f /var/log/sift-azure-setup.log
Success requires COMPLETE and a successful --verify, not merely starting the service.
No automatic reboot is performed. Reboot in your maintenance window, then run --verify.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
message() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
set_mode() {
    [ "$MODE_SET" -eq 0 ] || die "Choose only one mode."
    MODE=$1
    MODE_SET=1
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            [ "$#" -ge 2 ] || die "--user requires a local username."
            DESKTOP_USER=$2; USER_SET=1; shift 2 ;;
        --dry-run) set_mode dry-run; shift ;;
        --status) set_mode status; shift ;;
        --verify) set_mode verify; shift ;;
        --resume) set_mode resume; shift ;;
        --worker) set_mode worker; shift ;;
        --yes) YES=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
        *) die "Unknown argument: $1. Use --help." ;;
    esac
done

[[ "$DESKTOP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    die "Use a normal local Linux username, not root or an Entra email address."
[ "$DESKTOP_USER" != root ] || die "Do not use root as the desktop account."
[ "$(id -u)" -eq 0 ] || die "Run with sudo or as root."
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C.UTF-8

if [ -L "$STATE" ] || [ -L "$LOG" ]; then
    die "The setup state/log path must not be a symbolic link."
fi
if [ -e "$STATE" ]; then
    [ -d "$STATE" ] && [ "$(stat -c %u "$STATE")" -eq 0 ] ||
        die "Existing setup state is not a root-owned directory."
    [ -f "$STATE/product" ] && [ "$(cat "$STATE/product")" = sift-azure-setup ] ||
        die "The state directory belongs to another application; it was not changed."
    if [ -f "$STATE/user" ]; then
        saved_user=$(cat "$STATE/user")
        [[ "$saved_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid saved setup username."
        if [ "$USER_SET" -eq 1 ] && [ "$DESKTOP_USER" != "$saved_user" ]; then
            die "This deployment uses $saved_user. Do not change its account during resume."
        fi
        DESKTOP_USER=$saved_user
    fi
fi

if [ "$MODE" = status ]; then
    [ -f "$STATE/status" ] || die "No installation has been started by this script."
    cat "$STATE/status"
    systemctl show "$UNIT" -p ActiveState -p SubState -p MainPID -p ExecMainStatus
    if [ -f "$LOG" ]; then tail -n 20 "$LOG"; fi
    exit 0
fi

platform_check() {
    [ -r /etc/os-release ] || die "Cannot identify the operating system."
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] && [ "$(uname -m)" = x86_64 ] ||
        die "This version is tested only on Ubuntu 24.04 x86_64."
    [ "$(cat /proc/1/comm)" = systemd ] || die "A systemd VM is required; a normal container is not supported."
    for program in python3 netplan systemctl getent passwd runuser; do
        command -v "$program" >/dev/null || die "Required Ubuntu base command is missing: $program"
    done
    python3 -c 'import yaml' || die "Ubuntu's python3-yaml/Netplan prerequisite is missing."
}

account_info() {
    grep -q "^${DESKTOP_USER}:" /etc/passwd || die "$DESKTOP_USER must be a local account."
    DESKTOP_UID=$(id -u "$DESKTOP_USER")
    DESKTOP_GID=$(id -g "$DESKTOP_USER")
    DESKTOP_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
    [ "$DESKTOP_UID" -ge 1000 ] && [ "$DESKTOP_UID" -lt 65534 ] ||
        die "Refusing to configure a system account as the desktop user."
    case "$DESKTOP_HOME" in /home/*) ;; *) die "Use a dedicated account with its home under /home." ;; esac
    [ -d "$DESKTOP_HOME" ] && [ ! -L "$DESKTOP_HOME" ] ||
        die "The local account needs an existing, non-symlink home directory."
    case "$(getent passwd "$DESKTOP_USER" | cut -d: -f7)" in
        */nologin|*/false) die "The desktop account has a noninteractive login shell." ;;
    esac
    export DESKTOP_USER DESKTOP_UID DESKTOP_GID DESKTOP_HOME
}

network_renderer() {
    python3 - <<'PY'
import json
import subprocess
import yaml

def run(args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout

network = yaml.safe_load(run(["netplan", "get"])).get("network", {})
renderers = set()
if network.get("renderer"):
    renderers.add(network["renderer"])
for category in ("ethernets", "wifis", "bonds", "bridges", "vlans"):
    for settings in network.get(category, {}).values():
        if isinstance(settings, dict) and settings.get("renderer"):
            renderers.add(settings["renderer"])
if len(renderers) > 1:
    raise RuntimeError("Mixed Netplan renderers need administrator review; no network changes were made.")
if renderers:
    renderer = next(iter(renderers))
else:
    route = json.loads(run(["ip", "-j", "route", "get", "168.63.129.16"]))[0]
    interface = route.get("dev")
    nm_active = subprocess.run(["systemctl", "is-active", "--quiet", "NetworkManager"]).returncode == 0
    if nm_active and interface:
        state = run(["nmcli", "-g", "GENERAL.STATE", "device", "show", interface]).strip()
        renderer = "NetworkManager" if state.startswith("100") else None
    else:
        renderer = None
    if renderer is None and subprocess.run(
        ["systemctl", "is-active", "--quiet", "systemd-networkd"]
    ).returncode == 0:
        renderer = "networkd"
if renderer not in ("networkd", "NetworkManager"):
    raise RuntimeError("Cannot safely determine the active renderer. Set an explicit Netplan renderer first.")
print(renderer)
PY
}

installation_preflight() {
    platform_check
    free_kib=$(df -Pk / | awk 'NR == 2 { print $4 }')
    if [ ! -f "$STATE/hostname.original" ]; then
        [ "$free_kib" -ge 62914560 ] ||
            die "At least 60 GiB free space is required. Expand the Azure OS disk before installing."
    else
        [ "$free_kib" -ge 10485760 ] ||
            die "At least 10 GiB must remain to resume safely; review disk use before retrying."
    fi
    RENDERER=$(network_renderer) || die "Networking needs administrator review before desktop installation."
    if getent passwd "$DESKTOP_USER" >/dev/null; then account_info; fi
    message "OS: Ubuntu 24.04 x86_64; network renderer to preserve: $RENDERER"
    message "Desktop user: $DESKTOP_USER; free root space: $((free_kib / 1048576)) GiB"
    message "Installer: Cast $CAST_VERSION; SIFT release: $SIFT_RELEASE; public software umask: 022"
    message "Will install GNOME, TLS xrdp, full SIFT desktop, SQLite Browser and GTKHash."
    message "Azure NSGs/Bastion, disk size, account RBAC and SSH password authentication are NOT configured here."
}

set_phase() {
    PHASE=$1
    printf 'RUNNING phase=%s time=%s\n' "$PHASE" "$(date -u +%FT%TZ)" > "$STATE/status.new"
    chmod 0600 "$STATE/status.new"
    mv -f "$STATE/status.new" "$STATE/status"
    message "Phase: $PHASE"
}

save_ssh_permissions() {
    [ ! -f "$STATE/ssh-permissions.json" ] || return 0
    python3 - "$DESKTOP_HOME/.ssh" "$STATE/ssh-permissions.json" <<'PY'
import json
import os
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
records = []
if root.exists():
    if root.is_symlink():
        raise RuntimeError("The desktop account's .ssh directory must not be a symlink.")
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        for path in [Path(directory), *(Path(directory) / name for name in files)]:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                continue
            records.append({
                "path": str(path.relative_to(root)), "mode": stat.S_IMODE(info.st_mode),
                "uid": info.st_uid, "gid": info.st_gid,
            })
Path(sys.argv[2]).write_text(json.dumps(records))
PY
    chmod 0600 "$STATE/ssh-permissions.json"
}

restore_ssh_permissions() {
    [ -f "$STATE/ssh-permissions.json" ] || return 0
    python3 - "$DESKTOP_HOME/.ssh" "$STATE/ssh-permissions.json" "$DESKTOP_UID" "$DESKTOP_GID" <<'PY'
import json
import os
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
previous = {value["path"]: value for value in json.loads(Path(sys.argv[2]).read_text())}
if root.exists():
    if root.is_symlink():
        raise RuntimeError("Refusing to follow a replaced .ssh directory.")
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        for path in [Path(directory), *(Path(directory) / name for name in files)]:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                continue
            record = previous.get(str(path.relative_to(root)))
            if record:
                os.chown(path, record["uid"], record["gid"])
                os.chmod(path, record["mode"])
            else:
                os.chown(path, int(sys.argv[3]), int(sys.argv[4]))
                os.chmod(path, 0o700 if path.is_dir() else 0o600)
PY
}

prepare_microsoft_repository() {
    local repo=/etc/apt/sources.list.d/microsoft-prod.list
    local original_key=/usr/share/keyrings/microsoft-prod.gpg
    local target_key=/usr/share/keyrings/MICROSOFT.asc
    if [ -f "$STATE/microsoft-prod.list.original" ]; then
        cp -p "$STATE/microsoft-prod.list.original" "$repo"
    fi
    if [ ! -f "$repo" ]; then
        if grep -l 'packages.microsoft.com/ubuntu/24.04/prod' /etc/apt/sources.list.d/*.sources 2>/dev/null |
            grep -v '^/etc/apt/sources.list.d/microsoft.sources$' >/dev/null; then
            die "A nonstandard Microsoft product source needs manual reconciliation; no source was changed."
        fi
        return 0
    fi
    grep -Fq 'https://packages.microsoft.com/ubuntu/24.04/prod noble main' "$repo" ||
        die "The Microsoft repository format differs from the tested Ubuntu configuration."
    grep -Fq 'signed-by=/usr/share/keyrings/microsoft-prod.gpg' "$repo" ||
        die "The Microsoft repository uses an unexpected signing key; refusing to replace its trust."
    if [ ! -f "$STATE/microsoft-prod.list.original" ]; then
        cp -p "$repo" "$STATE/microsoft-prod.list.original"
    fi
    curl --fail --silent --show-error --location --retry 2 --max-time 120 \
        --proto '=https' --proto-redir '=https' \
        --output "$STATE/microsoft.asc" https://packages.microsoft.com/keys/microsoft.asc
    local old_fingerprints new_fingerprints
    old_fingerprints=$(gpg --batch --show-keys --with-colons "$original_key" |
        awk -F: '$1 == "fpr" { print $10 }' | sort)
    new_fingerprints=$(gpg --batch --show-keys --with-colons "$STATE/microsoft.asc" |
        awk -F: '$1 == "fpr" { print $10 }' | sort)
    [ -n "$old_fingerprints" ] && [ "$old_fingerprints" = "$new_fingerprints" ] ||
        die "Microsoft public signing fingerprints differ. Signature checking was NOT disabled."
    install -m 0644 "$STATE/microsoft.asc" "$target_key"
    sed -i 's#signed-by=/usr/share/keyrings/microsoft-prod.gpg#signed-by=/usr/share/keyrings/MICROSOFT.asc#g' "$repo"
    message "Temporarily reconciled Microsoft sources using identical signing fingerprints."
}

restore_microsoft_repository() {
    [ -f "$STATE/microsoft-prod.list.original" ] || return 0
    cp -p "$STATE/microsoft-prod.list.original" /etc/apt/sources.list.d/microsoft-prod.list || return 1
    if [ -f /etc/apt/sources.list.d/microsoft.sources ]; then
        grep -Fq 'URIs: https://packages.microsoft.com/ubuntu/24.04/prod' \
            /etc/apt/sources.list.d/microsoft.sources || return 1
        if [ -f "$STATE/microsoft.sources.original" ]; then
            cp -p "$STATE/microsoft.sources.original" /etc/apt/sources.list.d/microsoft.sources || return 1
        else
            rm -- /etc/apt/sources.list.d/microsoft.sources || return 1
        fi
    fi
}

restore_platform_settings() {
    local failed=0
    if [ "$CAST_ATTEMPTED" -eq 1 ]; then
        hostnamectl set-hostname "$(cat "$STATE/hostname.original")" || failed=1
        cp -p "$STATE/hosts.original" /etc/hosts || failed=1
        restore_ssh_permissions || failed=1
    fi
    restore_microsoft_repository || failed=1
    for name in smbd nmbd; do
        if [ -f "$STATE/$name.initial-active" ] &&
            [ "$(cat "$STATE/$name.initial-active")" != active ] &&
            [ "$(systemctl show "$name.service" -p LoadState --value)" = loaded ]; then
            systemctl stop "$name.service" || failed=1
            if [ "$(cat "$STATE/$name.initial-enabled")" != enabled ]; then
                systemctl disable "$name.service" || failed=1
            fi
        fi
    done
    if [ "$failed" -eq 0 ] && [ -f "$STATE/cast-in-progress" ]; then
        rm -- "$STATE/cast-in-progress" || failed=1
    fi
    return "$failed"
}

worker_exit() {
    local result=$?
    trap - EXIT ERR INT TERM
    if ! restore_platform_settings; then
        message "ERROR: Platform-setting restoration failed; inspect the log."
        result=1
    fi
    if [ "$result" -eq 0 ] && [ "$FINISHED" -eq 1 ]; then
        printf 'COMPLETE time=%s user=%s\n' "$(date -u +%FT%TZ)" "$DESKTOP_USER" > "$STATE/status"
        printf '0\n' > "$STATE/exit-code"
        if ! systemctl disable "$UNIT"; then
            message "ERROR: Could not disable the completed setup service."
            printf 'FAILED phase=service-cleanup exit=1\n' > "$STATE/status"
            result=1
        fi
        if [ "$result" -eq 0 ]; then
            message "Setup complete. Reboot in your maintenance window, then run --verify."
        else
            printf '%s\n' "$result" > "$STATE/exit-code"
        fi
    else
        [ "$result" -ne 0 ] || result=1
        printf 'FAILED phase=%s exit=%s time=%s\n' "$PHASE" "$result" "$(date -u +%FT%TZ)" > "$STATE/status"
        printf '%s\n' "$result" > "$STATE/exit-code"
        message "ERROR: Setup failed in $PHASE (exit $result). Fix the logged cause, then use --resume."
    fi
    chmod 0600 "$STATE/status" "$STATE/exit-code"
    exit "$result"
}

preserve_network_renderer() {
    local renderer
    renderer=$(network_renderer)
    python3 - "$STATE" "$renderer" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
state = Path(sys.argv[1])
renderer = sys.argv[2]
path = Path("/etc/netplan/99-sift-renderer.yaml")
marker = "# Managed by sift-azure-setup: preserve the pre-desktop renderer."
contents = marker + f"\nnetwork:\n  version: 2\n  renderer: {renderer}\n"
previous = path.read_bytes() if path.exists() else None
if previous is not None and marker.encode() not in previous:
    raise RuntimeError(f"Refusing to overwrite an existing unrelated Netplan file: {path}")
path.write_text(contents)
os.chmod(path, 0o600)
result = subprocess.run(["netplan", "generate"], text=True, capture_output=True)
if result.returncode:
    if previous is None:
        path.unlink()
    else:
        path.write_bytes(previous)
    raise RuntimeError(f"Netplan validation failed; the override was restored: {result.stderr}")
(state / "renderer").write_text(renderer + "\n")
print("Preserved network renderer:", renderer, "(no netplan apply or interface restart)")
PY
}

prefetch_exiftool() {
    local version checksum archive download
    version=$(curl --fail --silent --show-error --location --max-time 60 \
        https://exiftool.org/ver.txt | tr -d '\r\n')
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid ExifTool version metadata."
    curl --fail --silent --show-error --location --max-time 60 \
        --output "$STATE/exiftool-checksums.txt" https://exiftool.org/checksums.txt
    checksum=$(awk -v name="SHA2-256(Image-ExifTool-${version}.tar.gz)=" \
        '{ gsub(/\r/, ""); if ($1 == name) print $2 }' "$STATE/exiftool-checksums.txt")
    [[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || die "No valid publisher SHA-256 was found for ExifTool."
    archive="/var/cache/sift/archives/Image-ExifTool-${version}.tar.gz"
    download="$STATE/exiftool.download"
    curl --fail --show-error --location --retry 2 --connect-timeout 30 --max-time 300 \
        --proto '=https' --proto-redir '=https' --max-filesize 50000000 \
        --output "$download" \
        "https://downloads.sourceforge.net/project/exiftool/Image-ExifTool-${version}.tar.gz"
    printf '%s  %s\n' "$checksum" "$download" | sha256sum --check -
    install -d -m 0755 /var/cache/sift/archives
    install -m 0644 "$download" "$archive"
    rm -- "$download"
    printf '%s %s\n' "$version" "$checksum" > "$STATE/exiftool-version"
    message "Cached the official ExifTool $version archive with its publisher checksum."
}

repair_public_software_access() {
    # Only published SIFT software trees, never all of /opt, /usr, user homes or evidence.
    python3 - <<'PY'
import os
from pathlib import Path
import stat
roots = (
    "/opt/amcache", "/opt/pdf-tools", "/opt/zimmermantools",
    "/usr/share/regripper", "/usr/local/src/regripper/plugins",
    "/usr/share/tsk/sorter", "/usr/share/sift", "/usr/local/aws-cli",
)
parents = ("/usr/local/src/regripper", "/usr/share/tsk")
changed = 0
for name in parents:
    path = Path(name)
    if path.is_dir() and not path.is_symlink():
        info = path.stat()
        if info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700:
            path.chmod(0o755)
            changed += 1
for name in roots:
    root = Path(name)
    if not root.is_dir() or root.is_symlink():
        continue
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        subdirectories[:] = [value for value in subdirectories if value != ".git"]
        for path in [Path(directory), *(Path(directory) / value for value in files)]:
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode) or info.st_uid != 0:
                continue
            mode = stat.S_IMODE(info.st_mode)
            desired = mode
            if path.is_dir() and mode == 0o700:
                desired = 0o755
            elif path.is_file() and mode in (0o600, 0o700):
                desired = 0o755 if mode & 0o100 else 0o644
            if desired != mode:
                path.chmod(desired)
                changed += 1
print("Corrected restrictive modes on", changed, "published software objects.")
PY
}

configure_desktop() {
    install -d -o "$DESKTOP_UID" -g "$DESKTOP_GID" -m 0755 "$DESKTOP_HOME/Desktop"
    if [ -f "$DESKTOP_HOME/.xsession" ] && [ ! -f "$STATE/xsession.original" ]; then
        cp -p "$DESKTOP_HOME/.xsession" "$STATE/xsession.original"
    fi
    cat > "$STATE/xsession" <<'SESSION'
#!/bin/sh
export GNOME_SHELL_SESSION_MODE=ubuntu
export XDG_CURRENT_DESKTOP=ubuntu:GNOME
exec gnome-session --session=ubuntu
SESSION
    install -o "$DESKTOP_UID" -g "$DESKTOP_GID" -m 0700 "$STATE/xsession" "$DESKTOP_HOME/.xsession"
    if [ ! -f "$STATE/xrdp.ini.original" ]; then cp -p /etc/xrdp/xrdp.ini "$STATE/xrdp.ini.original"; fi
    grep -q '^security_layer=' /etc/xrdp/xrdp.ini || die "Unexpected xrdp.ini format."
    sed -i 's/^security_layer=.*/security_layer=tls/' /etc/xrdp/xrdp.ini
    usermod -aG ssl-cert xrdp
    if [ "$(systemctl show gnome-remote-desktop.service -p LoadState --value)" = loaded ]; then
        systemctl disable --now gnome-remote-desktop.service
    fi
    systemctl enable xrdp
    systemctl restart xrdp
    systemctl set-default graphical.target
    loginctl enable-linger "$DESKTOP_USER"
    systemctl start "user@${DESKTOP_UID}.service"
    for attempt in $(seq 1 30); do
        [ ! -S "/run/user/${DESKTOP_UID}/bus" ] || break
        sleep 1
    done
    [ -S "/run/user/${DESKTOP_UID}/bus" ] || die "The desktop user's D-Bus session did not start."
    case "$(cat "$STATE/renderer")" in
        networkd) current_wait=systemd-networkd-wait-online; old_wait=NetworkManager-wait-online ;;
        NetworkManager) current_wait=NetworkManager-wait-online; old_wait=systemd-networkd-wait-online ;;
        *) die "Invalid saved network renderer." ;;
    esac
    systemctl enable "${current_wait}.service"
    if [ "$(systemctl show "${old_wait}.service" -p LoadState --value)" = loaded ]; then
        systemctl disable --now "${old_wait}.service"
        systemctl reset-failed "${old_wait}.service"
    fi
}

configure_user_settings() {
    local setting
    for setting in automount automount-open; do
        runuser -u "$DESKTOP_USER" -- env HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
            gsettings set org.gnome.desktop.media-handling "$setting" false
    done
}

verify_workstation() {
    platform_check
    account_info
    [ "$(passwd -S "$DESKTOP_USER" | awk '{print $2}')" = P ] ||
        die "The desktop account does not have an unlocked local password."
    id -nG "$DESKTOP_USER" | tr ' ' '\n' | grep -qx sudo ||
        die "The desktop account does not have sudo membership."
    for package in ubuntu-desktop ubuntu-session xrdp xorgxrdp cast sqlitebrowser gtkhash; do
        [ "$(dpkg-query -W -f='${db:Status-Status}' "$package")" = installed ] ||
            die "Missing required package: $package"
    done
    systemctl is-active xrdp xrdp-sesman
    [ "$(systemctl is-enabled xrdp)" = enabled ] || die "xrdp is not enabled for boot."
    grep -qx 'security_layer=tls' /etc/xrdp/xrdp.ini || die "xrdp is not configured for TLS-only RDP."
    runuser -u xrdp -- test -r /etc/xrdp/key.pem || die "xrdp cannot read its TLS key."
    pamtester xrdp-sesman "$DESKTOP_USER" acct_mgmt
    [ "$(stat -c %u "$DESKTOP_HOME/.xsession")" -eq "$DESKTOP_UID" ] ||
        die "The session file belongs to the wrong user."
    [ "$(stat -c %a "$DESKTOP_HOME/.xsession")" = 700 ] || die "Unexpected session-file permissions."
    grep -q 'gnome-session --session=ubuntu' "$DESKTOP_HOME/.xsession" ||
        die "The user session does not start Ubuntu GNOME."
    runuser -u "$DESKTOP_USER" -- mmls -V
    runuser -u "$DESKTOP_USER" -- log2timeline.py --version
    runuser -u "$DESKTOP_USER" -- exiftool -ver
    runuser -u "$DESKTOP_USER" -- /opt/volatility3/bin/python3 -c \
        'import yara; from importlib.metadata import version; print("Volatility", version("volatility3"), "YARA Python", yara.__version__)'
    runuser -u "$DESKTOP_USER" -- env \
        XDG_DATA_DIRS=/usr/share/gnome:/usr/local/share:/usr/share:/var/lib/snapd/desktop \
        python3 - <<'PY'
from pathlib import Path
from urllib.request import urlopen
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio
for identifier in ("sqlitebrowser.desktop", "org.gtkhash.gtkhash.desktop",
                   "sift-tools.desktop", "sift-terminal.desktop", "sift-cyberchef.desktop"):
    application = Gio.DesktopAppInfo.new(identifier)
    if application is None or not application.should_show():
        raise RuntimeError(f"GNOME cannot discover the expected application: {identifier}")
catalogue = Path.home() / "Desktop/SIFT-Tools.html"
if not catalogue.is_file() or "SIFT Tools" not in catalogue.read_text():
    raise RuntimeError("The desktop tool catalogue is not readable.")
with urlopen("http://127.0.0.1/cyberchef/", timeout=20) as response:
    if response.status != 200 or b"CyberChef" not in response.read(200000):
        raise RuntimeError("The local CyberChef application is not responding.")
print("GUI application discovery and local CyberChef: passed")
PY
    python3 - "$DESKTOP_USER" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
import yaml
user = sys.argv[1]
path = Path("/var/cache/cast/installer/logs/results.yaml")
if not path.exists():
    raise RuntimeError("No completed SIFT installer result was found.")
states = yaml.safe_load(path.read_text())["local"]
failed = [value.get("__id__") for value in states.values() if value.get("result") is not True]
if failed:
    raise RuntimeError(f"SIFT has unsuccessful states: {failed[:15]}")
if not any(value.get("__id__") == "sift-desktop-include" for value in states.values()):
    raise RuntimeError("The completed SIFT installation is not desktop mode.")
paths = set()
for key, value in states.items():
    parts = key.split("_|-")
    if parts[0] == "virtualenv":
        paths.add(str(Path(value["name"]) / "bin/python3"))
    if parts[0] == "file" and parts[-1] == "symlink" and value["name"].startswith("/usr/local/bin/"):
        paths.add(value["name"])
code = 'import json,os,sys; print(json.dumps([p for p in json.load(sys.stdin) if not os.access(p,os.R_OK|os.X_OK)]))'
result = subprocess.run(
    ["runuser", "-u", user, "--", "python3", "-c", code],
    input=json.dumps(sorted(paths)), check=True, text=True, capture_output=True,
)
bad = json.loads(result.stdout)
if bad:
    raise RuntimeError(f"Installed tools are not accessible to {user}: {bad}")
print(json.dumps({"sift_states": len(states), "failed_states": 0, "user_executable_paths_checked": len(paths)}))
PY
    for setting in automount automount-open; do
        value=$(runuser -u "$DESKTOP_USER" -- env HOME="$DESKTOP_HOME" \
            XDG_RUNTIME_DIR="/run/user/${DESKTOP_UID}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
            gsettings get org.gnome.desktop.media-handling "$setting")
        [ "$value" = false ] || die "Automatic media handling is not disabled: $setting"
    done
    audit=$(dpkg --audit)
    [ -z "$audit" ] || die "dpkg reports an incomplete package configuration: $audit"
    df -h /
    message "VERIFICATION_PASSED: installed SIFT states, user access, GNOME session, GUI packages and TLS RDP."
    message "Still test an actual RDP login through your approved Azure Bastion/VPN path."
}

publish_catalogue() {
    python3 - "$DESKTOP_USER" "$STATE" <<'PY'
from html import escape
import json
import os
from pathlib import Path
import pwd
import subprocess
import sys
import yaml
user = pwd.getpwnam(sys.argv[1])
home = Path(user.pw_dir)
state = Path(sys.argv[2])
states = yaml.safe_load(Path("/var/cache/cast/installer/logs/results.yaml").read_text())["local"]
commands = set()
for key, value in states.items():
    if key.split("_|-")[0] == "file" and value["name"].startswith("/usr/local/bin/"):
        if Path(value["name"]).is_file():
            commands.add(Path(value["name"]).name)
core = {
    "Timeline analysis": "log2timeline.py --help",
    "Timeline export": "psort.py --help",
    "Memory analysis": "vol -h",
    "Filesystem analysis": "mmls -V",
    "Registry plugins": "rip.pl -l",
    "Amcache": "amcache.py -h",
    "Windows MFT": "MFTECmd -h",
    "Jump lists": "JLECmd -h",
    "PDF inspection": "pdfid.py --help",
    "PDF parsing": "pdf-parser.py --help",
    "Metadata": "exiftool -ver",
}
gui = (
    ("DB Browser for SQLite", "sqlitebrowser", "Inspect database working copies; use --read-only."),
    ("GTKHash", "gtkhash", "Calculate and compare SHA-256 and other file hashes."),
    ("Wireshark", "wireshark", "Analyze captured PCAP network traffic."),
    ("GHex / Hex Editor", "ghex", "Inspect bytes in a working copy of a file."),
    ("CyberChef (Local)", "http://127.0.0.1/cyberchef/", "Local browser-based decoding and transformation."),
)
rows = "".join(f"<tr><td>{escape(name)}</td><td><code>{escape(command)}</code></td></tr>" for name, command in core.items())
gui_rows = "".join(
    f"<tr><td>{escape(name)}</td><td><code>{escape(command)}</code></td><td>{escape(description)}</td></tr>"
    for name, command, description in gui
)
items = "".join(f"<li data-tool><code>{escape(command)}</code></li>" for command in sorted(commands, key=str.lower))
html = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>SIFT Tools</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:1050px;margin:30px auto;padding:0 20px;color:#203044}
table{border-collapse:collapse;width:100%}td,th{padding:10px;border-bottom:1px solid #ddd;text-align:left}
code{overflow-wrap:anywhere}input{font:inherit;padding:10px;width:95%}li{margin:7px 0}[hidden]{display:none}</style>
</head><body><h1>SIFT Tools</h1><p>Installed workstation tools for USERNAME.</p>
<h2>Graphical DFIR tools</h2><p>Search GNOME Activities for the application name.</p>
<table><tr><th>Application</th><th>Command / location</th><th>Purpose</th></tr>GUI_ROWS</table>
<p><a href="http://127.0.0.1/cyberchef/">Open local CyberChef inside this VM</a>.</p>
<p>Guymager is not installed because its Ubuntu libewf2 dependency conflicts with SIFT libewf.
Native Entra authentication is not supported for Linux RDP; use the local account.</p>
<h2>Common command-line tools</h2><p>Open SIFT Terminal. Most SIFT tools do not have individual GUI icons.</p>
<table><tr><th>Task</th><th>Command</th></tr>CLI_ROWS</table>
<h2>Installed custom command paths</h2><label for="search">Search tools</label><br>
<input id="search" type="search" placeholder="Filter installed commands"><p id="count"></p><ul>COMMANDS</ul>
<p>Preserve original evidence, use working copies and appropriate read-only mounting, record hashes and
chain of custody. A successful installation is not validation of every evidence format or tool feature.</p>
<script>const q=document.getElementById('search'),r=Array.from(document.querySelectorAll('[data-tool]'));
function f(){let n=0;for(const x of r){x.hidden=!x.textContent.toLowerCase().includes(q.value.toLowerCase());if(!x.hidden)n++;}
document.getElementById('count').textContent=n+' of '+r.length+' command paths';}q.addEventListener('input',f);f();</script>
</body></html>"""
for token, value in (("USERNAME", escape(user.pw_name)), ("GUI_ROWS", gui_rows), ("CLI_ROWS", rows), ("COMMANDS", items)):
    html = html.replace(token, value)
desktop = home / "Desktop"
desktop.mkdir(exist_ok=True)
applications = home / ".local/share/applications"
applications.mkdir(parents=True, exist_ok=True)
for directory in (desktop, home / ".local", home / ".local/share", applications):
    os.chown(directory, user.pw_uid, user.pw_gid)
catalogue = desktop / "SIFT-Tools.html"
catalogue.write_text(html)
os.chown(catalogue, user.pw_uid, user.pw_gid)
os.chmod(catalogue, 0o644)
entries = {
    "sift-tools.desktop": ("SIFT Tools", f'xdg-open "{catalogue}"', "applications-science", "Utility;"),
    "sift-terminal.desktop": ("SIFT Terminal", f'gnome-terminal --working-directory="{home}"', "utilities-terminal", "System;TerminalEmulator;"),
    "sift-cyberchef.desktop": ("CyberChef (Local)", "xdg-open http://127.0.0.1/cyberchef/", "applications-science", "Utility;"),
}
for filename, (name, command, icon, categories) in entries.items():
    target = applications / filename
    marker = "# Managed by sift-azure-setup"
    if target.exists() and marker not in target.read_text():
        backup = state / (filename + ".original")
        if not backup.exists():
            backup.write_bytes(target.read_bytes())
            backup.chmod(0o600)
    target.write_text(
        f"{marker}\n[Desktop Entry]\nType=Application\nName={name}\nExec={command}\n"
        f"Icon={icon}\nTerminal=false\nCategories={categories}\nKeywords=SIFT;DFIR;Forensics;\n"
    )
    os.chown(target, user.pw_uid, user.pw_gid)
    os.chmod(target, 0o644)
    subprocess.run(["desktop-file-validate", str(target)], check=True)
subprocess.run(["update-desktop-database", str(applications)], check=True)
print("Created GNOME launchers and", catalogue)
PY
}

platform_check
if [ "$MODE" = verify ]; then verify_workstation; exit 0; fi
if [ "$MODE" != dry-run ] && [ -f "$STATE/status" ] && grep -q '^COMPLETE ' "$STATE/status"; then
    message "This deployment is already complete; checking it instead of reinstalling."
    verify_workstation
    exit 0
fi

if [ "$MODE" = worker ]; then
    [ "${SIFT_SETUP_WORKER:-}" = 1 ] && [ -f "$STATE/user" ] ||
        die "The internal worker must be started by its setup service."
    account_info
    trap worker_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l CHECKPOINT_DISABLE=1
    PRIOR_RUN=0
    if [ -f "$STATE/hostname.original" ]; then PRIOR_RUN=1; fi
    if [ -f "$STATE/cast-in-progress" ]; then
        CAST_ATTEMPTED=1
        restore_platform_settings
        CAST_ATTEMPTED=0
    else
        restore_microsoft_repository
    fi
    installation_preflight
    set_phase baseline
    if [ ! -f "$STATE/hostname.original" ]; then
        hostname > "$STATE/hostname.original"
        cp -p /etc/hosts "$STATE/hosts.original"
        if [ -f /etc/apt/sources.list.d/microsoft.sources ]; then
            cp -p /etc/apt/sources.list.d/microsoft.sources "$STATE/microsoft.sources.original"
        fi
        for service in smbd nmbd; do
            systemctl show "$service.service" -p ActiveState --value > "$STATE/$service.initial-active"
            systemctl show "$service.service" -p UnitFileState --value > "$STATE/$service.initial-enabled"
        done
    fi
    save_ssh_permissions
    set_phase preserve-networking
    preserve_network_renderer
    set_phase desktop-packages
    if [ -n "$(dpkg --audit)" ]; then
        [ "$PRIOR_RUN" -eq 1 ] ||
            die "Another package operation changed the fresh VM during setup; wait for it and inspect before --resume."
        message "Recovering package configuration from this interrupted deployment."
        dpkg --configure -a
    fi
    apt-get -o DPkg::Lock::Timeout=600 update
    printf 'gdm3 shared/default-x-display-manager select gdm3\n' | debconf-set-selections
    apt-get -o DPkg::Lock::Timeout=600 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install -y \
        ubuntu-desktop xrdp xorgxrdp dbus-x11 ca-certificates curl gnupg tmux \
        python3-yaml python3-packaging python3-gi desktop-file-utils pamtester sqlitebrowser gtkhash
    set_phase configure-desktop
    configure_desktop
    set_phase install-cast
    curl --fail --show-error --location --retry 2 --connect-timeout 30 --max-time 600 \
        --proto '=https' --proto-redir '=https' --output "$STATE/cast.deb" \
        "https://github.com/ekristen/cast/releases/download/${CAST_VERSION}/cast-${CAST_VERSION}-linux-amd64.deb"
    printf '%s  %s\n' "$CAST_SHA256" "$STATE/cast.deb" | sha256sum --check -
    dpkg -i "$STATE/cast.deb"
    set_phase exiftool-publisher-cache
    prefetch_exiftool
    set_phase microsoft-repository-compatibility
    prepare_microsoft_repository
    set_phase sift-desktop
    CAST_ATTEMPTED=1
    touch "$STATE/cast-in-progress"
    cast install --mode=desktop --user="$DESKTOP_USER" "teamdfir/sift-saltstack@${SIFT_RELEASE}"
    set_phase preserve-platform-settings
    restore_platform_settings
    CAST_ATTEMPTED=0
    set_phase tool-access
    repair_public_software_access
    set_phase desktop-settings
    configure_user_settings
    publish_catalogue
    set_phase verification
    verify_workstation
    rm -- "$STATE/cast.deb"
    FINISHED=1
    exit 0
fi

installation_preflight
if [ "$MODE" = dry-run ]; then
    message "DRY_RUN_PASSED: no packages, accounts, networking, files or services were changed."
    exit 0
fi
case "$(systemctl show "$UNIT" -p ActiveState --value)" in
    active|activating|deactivating|reloading) die "Setup is already active. Use --status." ;;
esac
if [ -e "$STATE" ] && [ "$MODE" != resume ]; then
    die "A previous deployment exists. Inspect --status, then use --resume after fixing its failure."
fi
if [ "$MODE" = resume ] && [ ! -f "$STATE/user" ]; then
    die "There is no deployment to resume."
fi
if [ "$MODE" != resume ] && [ -n "$(dpkg --audit)" ]; then
    die "The VM already has an incomplete package configuration. Resolve it before installing."
fi

if [ "$YES" -ne 1 ]; then
    [ -t 0 ] || die "Use --yes only after preparing a local password account, backup and private Azure network."
    printf '\nConfirm a dedicated/backed-up VM and private Bastion/VPN-only RDP rules are ready. Type YES: '
    read -r acknowledgement
    [ "$acknowledgement" = YES ] || die "Installation was not authorized."
else
    grep -q "^${DESKTOP_USER}:" /etc/passwd &&
        [ "$(passwd -S "$DESKTOP_USER" | awk '{print $2}')" = P ] ||
        die "--yes requires an existing local account with an unlocked password; prepare it interactively first."
fi
if ! getent passwd "$DESKTOP_USER" >/dev/null; then
    [ -t 0 ] || die "Pre-create the local account and set its password through a trusted interactive session."
    adduser --disabled-password --gecos "DFIR analyst" "$DESKTOP_USER"
fi
account_info
if [ "$(passwd -S "$DESKTOP_USER" | awk '{print $2}')" != P ]; then
    [ -t 0 ] || die "Set a strong local password using sudo passwd $DESKTOP_USER, then rerun."
    passwd "$DESKTOP_USER"
fi
usermod -aG sudo "$DESKTOP_USER"

install -d -m 0700 "$STATE"
printf 'sift-azure-setup\n' > "$STATE/product"
printf '%s\n' "$DESKTOP_USER" > "$STATE/user"
chmod 0600 "$STATE/product" "$STATE/user"
[ -f "$0" ] || die "Save the script to a file before running it; do not pipe it to bash."
if [ "$(readlink -f "$0")" != "$STATE/setup-sift-azure.sh" ]; then
    install -m 0700 "$(readlink -f "$0")" "$STATE/setup-sift-azure.sh"
fi
touch "$LOG"
chmod 0600 "$LOG"
unit_path="/etc/systemd/system/$UNIT"
if [ -e "$unit_path" ] && ! grep -q '^# Managed by sift-azure-setup$' "$unit_path"; then
    die "Refusing to replace an unrelated service definition."
fi
cat > "$unit_path" <<UNIT
# Managed by sift-azure-setup
[Unit]
Description=GNOME and SANS SIFT workstation setup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
Group=root
Environment=HOME=/root
Environment=SIFT_SETUP_WORKER=1
UMask=0022
WorkingDirectory=/root
ExecStart=/bin/bash $STATE/setup-sift-azure.sh --worker --user $DESKTOP_USER
TimeoutStartSec=4h
TimeoutStopSec=120
RemainAfterExit=yes
Restart=no
StandardOutput=append:$LOG
StandardError=inherit

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$unit_path"
printf 'QUEUED time=%s user=%s\n' "$(date -u +%FT%TZ)" "$DESKTOP_USER" > "$STATE/status"
chmod 0600 "$STATE/status"
systemctl daemon-reload
systemctl enable "$UNIT"
systemctl start --no-block "$UNIT"
message "INSTALLATION_STARTED: the service continues independently of this SSH session."
message "Monitor with --status or: sudo tail -f $LOG"
message "Do not claim readiness until status is COMPLETE and --verify succeeds."
