#!/usr/bin/env bash
# et-healthcheck.sh — detect a wedged etserver ("alive but not serving") and
# restart it, but ONLY on the genuine wedge signature, so a transient probe
# blip can't kill a healthy live session. Run every minute by
# et-healthcheck.timer.
#
# Why: etserver can get stuck so that the process stays alive and keeps
# listening, but never completes a new handshake (e.g. spinning in
# Connection::writePacket on a half-open client socket after a laptop sleep /
# VPN drop, or all handshake workers blocked in readAll). systemd
# Restart=always never fires because nothing crashed. Clients then see the
# misleading "The Eternal Terminal daemon is not running".
#
# Probe: a real loopback ET handshake (needs passwordless `ssh localhost`) that
# runs `true` on the server and exits.
#   - healthy                           -> et exits 0 (~2-3s)
#   - WEDGE (accepts TCP, no handshake) -> hangs, KILLed by timeout -> 137/124  <-- the ONLY restart trigger
#   - transient / refused / other       -> fast non-zero (e.g. 1)               <-- IGNORED (systemd owns crashes)
#
# Lessons baked in:
#   * Restarting on ANY failure is harmful: fast exit-1 blips happen on a
#     healthy server, and every restart wipes the session table, which
#     disconnects the live client ("invalid key on reconnect").
#   * `timeout --signal=KILL` returns 137 (128+SIGKILL), NOT 124. Matching only
#     124 makes the restart branch unreachable.
#   * Re-probe to confirm before restarting, and enforce a cooldown so a
#     restart storm can't cascade.
set -u

me="$(id -un)"
ETBIN="${HOME}/.local/bin/et"
FIFO="${HOME}/.local/et/etserver.fifo"
# ET_PORT comes from the env file written by et-devvm's install.sh.
[ -r "${HOME}/.config/et-devvm/env" ] && . "${HOME}/.config/et-devvm/env"
PORT="${ET_PORT:-2022}"
PROBE_TIMEOUT=15            # seconds; healthy handshake ~2-3s, a wedge hangs past this
FAIL_THRESHOLD=3           # consecutive WEDGE probes before we restart
RESTART_COOLDOWN=600       # seconds; min gap between restarts (kills cascades)
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/et-healthcheck"
COUNTER="${STATE_DIR}/failcount"
LAST_RESTART="${STATE_DIR}/last_restart"
LOCK="${STATE_DIR}/lock"
PROBE_LOGDIR="/dev/shm/et-healthcheck-$(id -u)"   # throwaway client logs (tmpfs, per-user)

mkdir -p "${STATE_DIR}" "${PROBE_LOGDIR}"

# Single-instance guard so overlapping timer fires can't race the counter.
exec 9>"${LOCK}"
if ! flock -n 9; then
    echo "$(date -Is) another healthcheck instance is running; skipping" >&2
    exit 0
fi

log() { echo "$(date -Is) $*"; }

run_probe() {
    timeout --signal=KILL "${PROBE_TIMEOUT}" \
        "${ETBIN}" --silent --logdir="${PROBE_LOGDIR}" \
        --serverfifo="${FIFO}" --command true "${me}@localhost:${PORT}" \
        >/dev/null 2>&1
}

# The probe outlived PROBE_TIMEOUT and was killed: 137 = 128+SIGKILL (what
# `timeout --signal=KILL` actually returns), 124 = timeout's generic code, kept
# in case the signal is ever changed back to the default TERM.
is_wedge() { [ "$1" -eq 137 ] || [ "$1" -eq 124 ]; }

read_count() { [ -r "${COUNTER}" ] && cat "${COUNTER}" 2>/dev/null || echo 0; }
cleanup_probe_logs() { rm -f "${PROBE_LOGDIR}"/etclient-* 2>/dev/null; }

run_probe
rc=$?

# --- Healthy -------------------------------------------------------------
if [ "${rc}" -eq 0 ]; then
    if [ "$(read_count)" != "0" ]; then
        log "probe OK (exit 0) — resetting wedge counter"
    fi
    echo 0 > "${COUNTER}"
    cleanup_probe_logs
    exit 0
fi

# --- Transient / refused (NOT a wedge) -----------------------------------
# A fast non-zero exit means the server answered the socket fast (or nothing is
# listening, which systemd Restart=always owns). Neither is the "alive but
# wedged" state we restart for, so these must NEVER trip a restart.
if ! is_wedge "${rc}"; then
    log "probe failed transiently (exit ${rc}) — not a wedge, ignoring (counter=$(read_count))"
    cleanup_probe_logs
    exit 0
fi

# --- Wedge candidate (hung past ${PROBE_TIMEOUT}s, killed) ----------------
count=$(( $(read_count) + 1 ))
echo "${count}" > "${COUNTER}"
log "WEDGE probe hung (exit ${rc}) — consecutive wedge hits: ${count}/${FAIL_THRESHOLD}"

if [ "${count}" -lt "${FAIL_THRESHOLD}" ]; then
    log "below threshold — not restarting yet"
    cleanup_probe_logs
    exit 0
fi

# Confirmation re-probe: a real wedge stays hung. Wait 3s and probe once more;
# only a second hang confirms it and rules out a one-off stall.
sleep 3
run_probe
rc2=$?
if ! is_wedge "${rc2}"; then
    log "confirmation re-probe returned exit ${rc2} (not hung) — false alarm, resetting counter"
    echo 0 > "${COUNTER}"
    cleanup_probe_logs
    exit 0
fi
log "confirmation re-probe still hung (exit ${rc2}) — wedge confirmed"

# Cooldown: never restart more than once per ${RESTART_COOLDOWN}s. Stops the
# cascade where a just-restarted server briefly probes bad and gets kicked again.
now=$(date +%s)
if [ -r "${LAST_RESTART}" ]; then
    last=$(cat "${LAST_RESTART}" 2>/dev/null || echo 0)
    since=$(( now - last ))
    if [ "${since}" -lt "${RESTART_COOLDOWN}" ]; then
        log "in cooldown (${since}s < ${RESTART_COOLDOWN}s since last restart) — skipping"
        cleanup_probe_logs
        exit 0
    fi
fi

log "threshold reached + confirmed + cooldown clear — restarting etserver.service"
# Reap any stale etterminal orphaned by the wedge (best effort). Only runs at a
# confirmed-wedge restart, so it cannot disrupt a healthy session.
pkill -u "${me}" -x etterminal 2>/dev/null || true
systemctl --user restart etserver.service
rcr=$?
log "restart issued (systemctl exit ${rcr}) — resetting counter"
echo "${now}" > "${LAST_RESTART}"
echo 0 > "${COUNTER}"
cleanup_probe_logs
exit 0
