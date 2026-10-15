# Agent instructions: install Eternal Terminal on the user's dev VM

Goal: the user can run `et-vm` on their laptop and get a resilient shell on their
dev VM. Background is in README.md. Follow these steps in order and report
the outcome of each one. Don't skip verification.

## 0. Figure out where you are

- **Laptop** (macOS, usually): you reach the VM with `ssh <host>`. Ask the user
  for the ssh host/alias if `~/.ssh/config` doesn't make it obvious. Run the VM
  steps as `ssh <host> '...'`.
- **On the VM already**: run the VM steps directly, then give the user the
  laptop steps to run (or do them yourself if you also have laptop access).

Check whether your VM shell is inside an ET session:
`pstree -s $$ | grep -q etterminal && echo inside-ET`. `install.sh` checks this too.
If you are, **never** run `systemctl --user restart etserver.service` yourself.
It kills your own session. Hand that command to the user.

## 1. VM: install the server

```bash
git clone https://github.com/mihac-cerebras/et-devvm ~/src/et-devvm 2>/dev/null \
  || git -C ~/src/et-devvm pull --ff-only
cd ~/src/et-devvm && ./install.sh --prebuilt
```

- If `ssh localhost` fails, the installer warns about it. Ask the user before re-running with
  `--setup-localhost-ssh`, because it edits `~/.ssh/authorized_keys`.
- If the prebuilt binaries can't run (missing libs), fall back to `./install.sh`
  (source build, 30-45 min). Run it in the background or under
  `systemd-run --user --unit=et-build ...` so a dropped connection doesn't kill it.
- If something already listens on 2022, use `--port <other>` and use the same
  port in the client alias.
- The installer ends with `loopback ET session OK` and prints the client setup.
  Keep that output, because it has the exact fifo path, user, host and port.

## 2. Laptop: client

1. `command -v et || brew install MisterTea/et/et` (Nix users: add
   `eternal-terminal` to their config instead of brew).
2. `ssh -o BatchMode=yes <user>@<vm-fqdn> true` must succeed. ET bootstraps over
   ssh. If it fails, fix ssh first. Don't continue.
3. Add the `et-vm()` function the installer printed to the user's shell rc
   (`~/.zshrc` or `~/.bashrc`). **Check first** whether the rc is a read-only
   symlink (home-manager/nix, chezmoi, …). If it is, add it to their dotfile
   source instead, or give the user the line.

## 3. Verify end to end (laptop)

`et` needs a TTY. From a non-interactive tool, wrap it:

```bash
script -q /dev/null et --serverfifo=<fifo> <user>@<vm-fqdn>:2022 -c 'echo ET_OK; exit'   # macOS script syntax
```

Expect `ET_OK`. Exit 134 with `TerminalClient.cpp ... No such file or directory`
means no TTY, not a server problem. Failures to look into:
- `Connection refused` / timeout: port 2022 isn't reachable from the laptop
  (VPN/firewall). Check `nc -vz <vm> 2022`.
- `The Eternal Terminal daemon is not running`: wrong `--serverfifo`, or the
  server is wedged. Run `ssh <vm> systemctl --user restart etserver.service`
  and retry.

## 4. Report

Tell the user the installed version (`~/.local/bin/etserver --version`), port,
whether linger and loopback ssh are OK (watchdog functional), and the exact
`et-vm` line you added and where you added it.
