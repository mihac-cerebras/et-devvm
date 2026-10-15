#!/usr/bin/env bash
# install.sh — install an Eternal Terminal (ET) server on a dev VM as a normal
# user (no sudo): binaries in ~/.local/bin, user-level systemd units, a wedge
# watchdog, and daily log cleanup. Safe to re-run (it upgrades in place).
#
# Run ON THE VM, from a clone of this repo:
#   ./install.sh                     # latest prebuilt release (~1 min)
#   ./install.sh --from-source       # build ET from upstream source (~30-45 min)
#
# See ./install.sh --help and README.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_REPO="${ET_RELEASE_REPO:-mihac-cerebras/et-devvm}"

ET_PORT="${ET_PORT:-2022}"
ET_REF="${ET_REF:-master}"
ET_SRC="${ET_SRC:-$HOME/src/EternalTerminal}"
MODE=prebuilt
PREBUILT_SRC=latest
RUN_TESTS=1
FORCE_RESTART=0
SETUP_LOCALHOST_SSH=0
HEALTHCHECK=0
# Parallel compile jobs: ~2 GB per job (protobuf-heavy TUs), capped at nproc.
# Too many and the VM's OOM daemon kills cc1plus.
JOBS="${ET_JOBS:-$(awk -v n="$(nproc 2>/dev/null || echo 4)" \
    '/^MemAvailable:/ {j=int($2/1024/1024/2); if (j>n) j=n; if (j<1) j=1; print j}' /proc/meminfo 2>/dev/null || echo 2)}"

BIN_DIR="$HOME/.local/bin"
ET_DIR="$HOME/.local/et"
FIFO="$ET_DIR/etserver.fifo"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/et-devvm"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/et-devvm"
UNITS=(etserver.service et-healthcheck.service et-healthcheck.timer etlog-cleanup.service etlog-cleanup.timer)
BINS=(et etserver etterminal)
MARKER="installed by et-devvm"

usage() {
    cat <<EOF
Usage: $0 [options]

  --prebuilt [URL|FILE]  Install a prebuilt tarball (default). With no argument,
                         downloads the latest release of $RELEASE_REPO
                         (built monthly by GitHub Actions from upstream ET).
  --from-source          Build from upstream source instead.
  --ref REF              Upstream git ref to build (implies --from-source; default: $ET_REF).
  --src DIR              Where to clone/build ET (default: $ET_SRC).
  --port N               TCP port for etserver (default: $ET_PORT).
  --skip-tests           Don't run et-test after a source build.
  --restart              Restart a running etserver even if this shell is itself
                         inside an ET session (that session WILL drop).
  --healthcheck          Enable the wedge watchdog (et-healthcheck.timer). Off by
                         default; re-running without this flag turns it off again.
  --setup-localhost-ssh  Append your own public key to ~/.ssh/authorized_keys so
                         the watchdog's loopback probe (ssh localhost) works.
  -h, --help             Show this help.

Environment overrides: ET_PORT, ET_REF, ET_SRC, ET_JOBS, ET_RELEASE_REPO.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prebuilt)
            MODE=prebuilt
            if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then PREBUILT_SRC="$2"; shift; fi ;;
        --from-source) MODE=source ;;
        --ref) ET_REF="$2"; MODE=source; shift ;;
        --src) ET_SRC="$2"; shift ;;
        --port) ET_PORT="$2"; shift ;;
        --skip-tests) RUN_TESTS=0 ;;
        --restart) FORCE_RESTART=1 ;;
        --healthcheck) HEALTHCHECK=1 ;;
        --setup-localhost-ssh) SETUP_LOCALHOST_SSH=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# True if this shell is (transitively) running under etterminal, i.e. the
# caller is connected over ET and restarting etserver would cut them off.
inside_et() {
    local pid=$$ comm
    while [ "${pid:-0}" -gt 1 ]; do
        comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
        [ "$comm" = etterminal ] && return 0
        pid="$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)"
    done
    return 1
}

# PIDs listening on $ET_PORT (empty if none or not visible).
port_listeners() {
    ss -Hltnp "sport = :$ET_PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}

# ---------------------------------------------------------------------------
preflight() {
    step "Preflight"
    [ "$(uname -s)" = Linux ] || die "this installs the ET *server* and must run on the Linux VM, not your laptop"
    [ "$(uname -m)" = x86_64 ] || [ "$MODE" = source ] || die "prebuilt binaries are x86_64 only; use --from-source"
    [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root"
    case "$ET_PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
    systemctl --user show-environment >/dev/null 2>&1 \
        || die "systemctl --user is not usable in this shell (no user systemd instance / DBUS session)"

    if [ -r /etc/os-release ]; then . /etc/os-release; info "OS: ${PRETTY_NAME:-unknown}"; fi
    case "${ID:-} ${ID_LIKE:-}" in *rhel*|*rocky*|*centos*|*fedora*) ;; *)
        [ "$MODE" = prebuilt ] && warn "prebuilt binaries target EL9 (Rocky/RHEL 9); this OS may not run them" ;;
    esac

    local missing=() c
    for c in ss awk tar curl flock timeout script ssh pkill; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "$MODE" = source ]; then
        for c in git gcc g++ make cmake perl autoconf automake libtoolize pkg-config zip unzip patch; do
            command -v "$c" >/dev/null 2>&1 || missing+=("$c")
        done
        perl -MIPC::Cmd -e1 2>/dev/null || missing+=("perl-IPC-Cmd")
        perl -MFindBin -e1 2>/dev/null || missing+=("perl-FindBin")
        printf '#include <libunwind.h>\n' | gcc -E -x c - >/dev/null 2>&1 || missing+=("libunwind-devel (EPEL)")
    fi
    [ ${#missing[@]} -eq 0 ] || die "missing tools/packages: ${missing[*]}
       ask an admin to 'dnf install' them, or drop --from-source to use prebuilt binaries"

    # Port must be free, or held by our own etserver (upgrade case).
    local pids pid
    pids="$(port_listeners)"
    for pid in $pids; do
        [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = etserver ] && [ -O "/proc/$pid" ] && continue
        die "port $ET_PORT is already in use by pid $pid ($(cat "/proc/$pid/comm" 2>/dev/null || echo '?')); pick another with --port"
    done
    if [ -z "$pids" ] && ss -Hltn "sport = :$ET_PORT" 2>/dev/null | grep -q .; then
        die "port $ET_PORT is in use by another user's process; pick another with --port"
    fi

    # Linger keeps the user systemd instance (and etserver) alive after logout.
    if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
        if loginctl enable-linger "$USER" 2>/dev/null; then
            info "enabled systemd linger for $USER"
        else
            warn "could not enable linger: etserver will stop when you have no login session left.
       Ask an admin to run: sudo loginctl enable-linger $USER"
        fi
    fi

    # The watchdog probes via a loopback ET connection, which bootstraps over ssh.
    if [ "$SETUP_LOCALHOST_SSH" = 1 ]; then setup_localhost_ssh; fi
    if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 localhost true 2>/dev/null; then
        LOCALHOST_SSH=1
    else
        LOCALHOST_SSH=0
        if [ "$HEALTHCHECK" = 1 ]; then
            warn "passwordless 'ssh localhost' does not work, so the wedge watchdog can't probe ET
       (it will just log failures and never restart anything). Fix: re-run with --setup-localhost-ssh"
        else
            info "passwordless 'ssh localhost' not available; skipping the loopback check"
        fi
    fi
}

setup_localhost_ssh() {
    local key="$HOME/.ssh/id_ed25519"
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    if [ ! -f "$key.pub" ]; then
        info "generating $key (no passphrase) for loopback ssh"
        ssh-keygen -q -t ed25519 -N '' -C "$USER@$(hostname -s) et-devvm loopback" -f "$key"
    fi
    touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    if ! grep -qF "$(cut -d' ' -f2 "$key.pub")" "$HOME/.ssh/authorized_keys"; then
        cat "$key.pub" >> "$HOME/.ssh/authorized_keys"
        info "added $key.pub to ~/.ssh/authorized_keys"
    fi
}

# ---------------------------------------------------------------------------
# Both paths leave the three binaries in $STAGE.
fetch_prebuilt() {
    step "Fetching prebuilt binaries ($PREBUILT_SRC)"
    local dl="$CACHE_DIR/download" tarball url
    rm -rf "$dl" && mkdir -p "$dl"
    if [ "$PREBUILT_SRC" = latest ]; then
        url="https://github.com/$RELEASE_REPO/releases/latest/download/et-el9-x86_64.tar.gz"
    else
        url="$PREBUILT_SRC"
    fi
    if [ -f "$url" ]; then
        tarball="$url"
        [ -f "$url.sha256" ] && cp "$url.sha256" "$dl/et.tar.gz.sha256"
    else
        tarball="$dl/et.tar.gz"
        curl -fsSL --retry 3 -o "$tarball" "$url" || die "download failed: $url"
        curl -fsSL --retry 3 -o "$dl/et.tar.gz.sha256" "$url.sha256" 2>/dev/null || true
    fi
    if [ -s "$dl/et.tar.gz.sha256" ]; then
        echo "$(awk '{print $1}' "$dl/et.tar.gz.sha256")  $tarball" | sha256sum -c - >/dev/null \
            || die "checksum mismatch for $url"
        info "sha256 OK"
    else
        warn "no .sha256 next to $url; skipping checksum"
    fi
    tar -xzf "$tarball" -C "$dl"
    STAGE="$(dirname "$(find "$dl" -type f -name etserver | head -1)")"
    [ -n "$STAGE" ] && [ -x "$STAGE/etserver" ] || die "tarball does not contain etserver"
    [ -f "$STAGE/VERSION" ] && sed 's/^/    /' "$STAGE/VERSION"

    local b
    for b in "${BINS[@]}"; do
        [ -x "$STAGE/$b" ] || die "tarball is missing $b"
        if ldd "$STAGE/$b" | grep -q 'not found'; then
            die "$b can't run here (missing shared libraries):
$(ldd "$STAGE/$b" | grep 'not found')
       (libunwind comes from EPEL: 'sudo dnf install libunwind'). Or use --from-source."
        fi
    done
}

# vcpkg's libsodium port needs autoconf-archive's m4 macros. It's often not
# installed and we have no sudo, so unpack the distro RPM into a cache dir and
# point aclocal at it.
ensure_autoconf_archive() {
    if rpm -q autoconf-archive >/dev/null 2>&1; then return; fi
    local dir="$CACHE_DIR/autoconf-archive"
    if [ ! -f "$dir/usr/share/aclocal/ax_check_compile_flag.m4" ]; then
        info "autoconf-archive not installed; unpacking it into $dir (no sudo needed)"
        rm -rf "$dir" && mkdir -p "$dir"
        if (cd "$dir" && dnf -q download autoconf-archive >/dev/null 2>&1 && rpm2cpio autoconf-archive-*.rpm | cpio -idm --quiet); then
            :
        else
            local v=2024.10.16
            info "dnf download failed; fetching autoconf-archive $v from ftp.gnu.org"
            curl -fsSL "https://ftp.gnu.org/gnu/autoconf-archive/autoconf-archive-$v.tar.xz" | tar -xJ -C "$dir" \
                || die "could not obtain autoconf-archive; ask an admin to 'dnf install autoconf-archive'"
            mkdir -p "$dir/usr/share" && mv "$dir/autoconf-archive-$v/m4" "$dir/usr/share/aclocal"
        fi
    fi
    export ACLOCAL_PATH="$dir/usr/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"
}

build_from_source() {
    step "Building ET from source ($ET_REF) in $ET_SRC"
    info "this takes ~30-45 min the first time (vcpkg builds protobuf/openssl/abseil); later rebuilds are faster"
    if [ ! -d "$ET_SRC/.git" ]; then
        mkdir -p "$(dirname "$ET_SRC")"
        git clone https://github.com/MisterTea/EternalTerminal "$ET_SRC"
    fi
    cd "$ET_SRC"
    # Our only local modification; drop it so checkout/pull can't conflict.
    git checkout -- vcpkg.json 2>/dev/null || true
    git fetch --tags origin
    if git rev-parse -q --verify "origin/$ET_REF^{commit}" >/dev/null; then
        git checkout -q --detach "origin/$ET_REF"
    else
        git checkout -q --detach "$ET_REF"
    fi
    git submodule sync -q --recursive
    git submodule update --init --recursive
    info "at $(git log -1 --format='%h %s')"

    # sentry-native is crash reporting to a Sentry backend; drop it from the
    # vcpkg deps (and DISABLE_SENTRY below) so we don't build/ship it.
    sed -i '/"sentry-native",/d' vcpkg.json

    ensure_autoconf_archive
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DDISABLE_SENTRY=ON
    cmake --build build -j"$JOBS"
    if [ "$RUN_TESTS" = 1 ]; then
        step "Running et-test"
        ./build/et-test
    fi
    STAGE="$ET_SRC/build"
    cd "$REPO_DIR"
}

# ---------------------------------------------------------------------------
install_binaries() {
    step "Installing binaries to $BIN_DIR"
    mkdir -p "$BIN_DIR" "$ET_DIR/log" "$CONF_DIR"
    CHANGED=0
    local b
    for b in "${BINS[@]}"; do
        cp "$STAGE/$b" "$BIN_DIR/.$b.new"
        strip "$BIN_DIR/.$b.new" 2>/dev/null || true
        chmod 755 "$BIN_DIR/.$b.new"
        if [ -f "$BIN_DIR/$b" ] && cmp -s "$BIN_DIR/.$b.new" "$BIN_DIR/$b"; then
            rm -f "$BIN_DIR/.$b.new"
            continue
        fi
        # mv, not cp: overwriting a running executable in place fails (ETXTBSY).
        mv -f "$BIN_DIR/.$b.new" "$BIN_DIR/$b"
        CHANGED=1
    done
    info "$("$BIN_DIR/etserver" --version 2>&1 | head -1)"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
        warn "$BIN_DIR is not on your PATH. ET clients need to find 'etterminal' there when they connect;
       add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to ~/.bashrc (or your shell rc)" ;;
    esac
}

install_units() {
    step "Installing systemd user units to $UNIT_DIR"
    mkdir -p "$UNIT_DIR" "$CONF_DIR"
    local ts u old
    ts="$(date +%Y%m%d-%H%M%S)"

    old="$(cat "$CONF_DIR/env" 2>/dev/null || true)"
    printf '# %s\nET_PORT=%s\n' "$MARKER" "$ET_PORT" > "$CONF_DIR/env"
    [ "$old" = "$(cat "$CONF_DIR/env")" ] || CHANGED=1

    for u in "${UNITS[@]}"; do
        if [ -f "$UNIT_DIR/$u" ] && ! grep -q "$MARKER" "$UNIT_DIR/$u"; then
            cp "$UNIT_DIR/$u" "$UNIT_DIR/$u.bak-$ts"
            info "backed up your existing $u to $u.bak-$ts"
        fi
        if ! cmp -s "$REPO_DIR/systemd/$u" "$UNIT_DIR/$u"; then
            cp "$REPO_DIR/systemd/$u" "$UNIT_DIR/$u"
            [ "$u" = etserver.service ] && CHANGED=1
        fi
    done
    if [ -f "$BIN_DIR/et-healthcheck.sh" ] && ! cmp -s "$REPO_DIR/bin/et-healthcheck.sh" "$BIN_DIR/et-healthcheck.sh" \
        && ! grep -q "et-devvm" "$BIN_DIR/et-healthcheck.sh"; then
        cp "$BIN_DIR/et-healthcheck.sh" "$BIN_DIR/et-healthcheck.sh.bak-$ts"
        info "backed up your existing et-healthcheck.sh"
    fi
    install -m 755 "$REPO_DIR/bin/et-healthcheck.sh" "$BIN_DIR/et-healthcheck.sh"
    systemctl --user daemon-reload
}

start_services() {
    step "Starting services"
    systemctl --user enable -q etserver.service etlog-cleanup.timer
    if ! systemctl --user is-active -q etserver.service; then
        systemctl --user start etserver.service
        info "etserver started"
    elif [ "$CHANGED" = 1 ]; then
        if inside_et && [ "$FORCE_RESTART" != 1 ]; then
            RESTART_PENDING=1
            warn "etserver needs a restart to pick up the new version, but this shell is running
       inside an ET session, which the restart would kill. Run this yourself when ready
       (your ET client will reconnect as a fresh session):
           systemctl --user restart etserver.service
       or re-run this script with --restart."
        else
            info "restarting etserver (open ET sessions will drop and must reconnect)"
            systemctl --user restart etserver.service
        fi
    else
        info "etserver already running and up to date"
    fi
    systemctl --user start etlog-cleanup.timer
    if [ "$HEALTHCHECK" = 1 ]; then
        systemctl --user enable -q --now et-healthcheck.timer
        info "wedge watchdog (et-healthcheck.timer) enabled"
    else
        systemctl --user disable -q --now et-healthcheck.timer 2>/dev/null || true
        info "wedge watchdog disabled (pass --healthcheck to enable)"
    fi
}

verify() {
    step "Verifying"
    local i
    for _ in $(seq 1 20); do
        [ -S "$FIFO" ] && ss -Hltn "sport = :$ET_PORT" | grep -q . && break
        sleep 1
    done
    systemctl --user is-active -q etserver.service || die "etserver.service is not active:
$(systemctl --user status etserver.service --no-pager 2>&1 | tail -15)"
    ss -Hltn "sport = :$ET_PORT" | grep -q . || die "nothing is listening on port $ET_PORT"
    info "etserver.service active, listening on :$ET_PORT, fifo $FIFO"
    if systemctl --user is-active -q et-healthcheck.timer; then info "et-healthcheck.timer active"; fi

    if [ "${RESTART_PENDING:-0}" = 1 ]; then
        info "(skipping loopback probe: old etserver still running until you restart it)"
    elif [ "$LOCALHOST_SSH" = 1 ]; then
        # et needs a TTY; `script` provides one when we're run non-interactively.
        local logdir rc=0
        logdir="$(mktemp -d)"
        timeout --signal=KILL 30 script -qec \
            "'$BIN_DIR/et' --silent --logdir='$logdir' --serverfifo='$FIFO' --command true '$USER@localhost:$ET_PORT'" \
            /dev/null >/dev/null 2>&1 || rc=$?
        rm -rf "$logdir"
        if [ "$rc" = 0 ]; then
            info "loopback ET session OK"
        else
            die "loopback ET session failed (exit $rc). Server log: $ET_DIR/log"
        fi
    fi
}

print_client() {
    local host
    host="$(hostname -f 2>/dev/null || hostname)"
    step "Done. Set up the client on your laptop"
    cat <<EOF
    1. Install the ET client:
         macOS:  brew install MisterTea/et/et
         nix:    eternal-terminal (nixpkgs)
    2. Make sure plain 'ssh $USER@$host' works from the laptop without a
       password prompt (ET bootstraps over ssh, then switches to port $ET_PORT).
    3. Add to ~/.zshrc (or ~/.bashrc) on the laptop:

         et-vm() { et -k 5 --serverfifo=$FIFO "\$@" $USER@$host:$ET_PORT; }

       --serverfifo is required: this etserver runs as you, not root, so its
       socket isn't at ET's default /var/run/etserver.idpasskey.fifo.
       Extra options go before the host ("\$@" comes first), which works with
       both old and new ET clients.
    4. Connect:  et-vm        (or: et-vm --command 'tmux new -A -s main' --noexit)
EOF
}

preflight
if [ "$MODE" = prebuilt ]; then fetch_prebuilt; else build_from_source; fi
install_binaries
install_units
start_services
verify
print_client
