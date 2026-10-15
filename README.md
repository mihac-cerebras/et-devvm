# et-devvm

Run an [Eternal Terminal](https://eternalterminal.dev) (ET) server on your dev VM
**as your normal user, without sudo**, plus a client alias on your laptop.
ET is like ssh, but sessions survive laptop sleep, Wi-Fi changes and VPN drops.

> **Using an AI agent?** Point it at this repo and say *"install ET on my dev VM
> following AGENTS.md"*. [AGENTS.md](AGENTS.md) has step-by-step instructions it can follow.

## What you get

| On the VM (`~` = your home) | Purpose |
|---|---|
| `~/.local/bin/{et,etserver,etterminal}` | ET binaries (upstream, EL9 x86_64) |
| `etserver.service` (systemd `--user`) | runs `etserver` on port 2022, restarts on crash, cleans up stale sockets/ports first |
| `et-healthcheck.timer` + `~/.local/bin/et-healthcheck.sh` | **opt-in (`--healthcheck`), off by default.** Every minute, opens a loopback ET session. If etserver is **alive but wedged** (it accepts TCP but never finishes a handshake, so systemd never notices), it restarts it. It only does that when the probe hangs, so a transient blip can't kill your live session |
| `etlog-cleanup.timer` | daily pruning of `~/.local/et/log` |
| `~/.config/et-devvm/env` | `ET_PORT=…` |

## Install

On the **VM**:

```bash
git clone https://github.com/mihac-cerebras/et-devvm ~/src/et-devvm
cd ~/src/et-devvm
./install.sh                     # ~1 min: latest release built by GitHub Actions
# or
./install.sh --from-source       # ~30-45 min: build upstream master from source
```

The script is idempotent. Re-run it to upgrade. Useful flags: `--port N`, `--ref <upstream ref>`,
`--healthcheck`, `--setup-localhost-ssh`, `--restart`. See `./install.sh --help`.

At the end it prints the client setup. On your **laptop**:

```bash
brew install MisterTea/et/et                     # or nixpkgs: eternal-terminal
# ~/.zshrc  (use your VM user, host and home):
et-vm() { et -k 5 --serverfifo=/cb/home/$USER/.local/et/etserver.fifo "$@" $USER@<you>-vm.cerebras.aws:2022; }
```

`--serverfifo` is mandatory. The server runs as you, not root, so its socket is not
at ET's default path. Plain `ssh <user>@<vm>` must also work without a password
prompt, because ET bootstraps over ssh and then switches to port 2022.

## Diagnose

```bash
systemctl --user status etserver.service et-healthcheck.timer
journalctl --user -u et-healthcheck.service -n 50     # "WEDGE"/"restart" lines
ls -t ~/.local/et/log | head                         # etserver logs
cat ~/.local/state/et-healthcheck/{failcount,last_restart}
```

Exit `137` in the healthcheck log means a real wedge (the probe hung and was killed).
Exit `1` is a fast, transient failure and is ignored on purpose.

## Releases (GitHub Actions)

`.github/workflows/release.yml` runs on the 1st of each month and on demand
(**Actions → Build ET release → Run workflow**, optional `ref`/`force`). It:

1. resolves upstream `MisterTea/EternalTerminal@master` and exits if a release
   for that commit already exists;
2. builds it in a `rockylinux:9` container with `ci/build.sh` (Sentry disabled,
   no libutempter, so the binaries need only libs every VM has), and runs `et-test`;
3. publishes `et-el9-x86_64.tar.gz` + `.sha256` as release `et-<version>-<sha>`,
   marked latest, which is what `install.sh` downloads by default.

## Uninstall

```bash
./uninstall.sh            # stop + remove units and binaries
./uninstall.sh --purge    # also logs, caches, and ~/src/EternalTerminal
```
