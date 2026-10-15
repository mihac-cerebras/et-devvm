#!/usr/bin/env bash
# uninstall.sh — remove what install.sh set up. Leaves the source checkout
# (~/src/EternalTerminal) and ~/.local/et/log alone unless --purge is given.
# Backups install.sh made (*.bak-*) are left in place.
set -euo pipefail
PURGE=0
[ "${1:-}" = --purge ] && PURGE=1

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/et-devvm"

systemctl --user disable --now et-healthcheck.timer etlog-cleanup.timer etserver.service 2>/dev/null || true
for u in etserver.service et-healthcheck.service et-healthcheck.timer etlog-cleanup.service etlog-cleanup.timer; do
    if [ -f "$UNIT_DIR/$u" ] && grep -q "installed by et-devvm" "$UNIT_DIR/$u"; then
        rm -f "$UNIT_DIR/$u"
    fi
done
systemctl --user daemon-reload
rm -f "$HOME/.local/bin/"{et,etserver,etterminal,et-healthcheck.sh}
rm -rf "$CONF_DIR" "${XDG_STATE_HOME:-$HOME/.local/state}/et-healthcheck" "/dev/shm/et-healthcheck-$(id -u)"
rm -f "$HOME/.local/et/etserver.fifo"
if [ "$PURGE" = 1 ]; then
    rm -rf "$HOME/.local/et" "${XDG_CACHE_HOME:-$HOME/.cache}/et-devvm" "${ET_SRC:-$HOME/src/EternalTerminal}"
fi
echo "ET server removed.$([ "$PURGE" = 1 ] || echo ' (kept ~/.local/et/log and the source checkout; --purge removes them)')"
