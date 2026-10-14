# sparkLimiter

Cap the GPU graphics clock on all your **NVIDIA DGX Spark** machines with one command, and keep the cap after reboots.

It finds your Sparks automatically, then runs

```bash
sudo nvidia-smi -lgc 0,2200
```

on each one and installs a small systemd service so the limit is re-applied at boot.

## Why

Limiting the maximum GPU clock lowers power draw, heat and fan noise, and can keep sustained workloads steadier. `nvidia-smi -lgc` does not survive a reboot, so this tool also sets up the boot-time service.

## Quick start

Run it from your laptop/workstation, or from one of the Sparks:

```bash
git clone https://github.com/<you>/sparkLimiter.git
cd sparkLimiter
./spark-limiter.sh
```

```
Discovering DGX Sparks (ssh config, known_hosts, mDNS, neighbours)...
Found 3 DGX Spark(s):
  1) localhost                    hostname: spark3
  2) spark1                       hostname: spark1
  3) spark4.local                 hostname: spark4
Apply to [Enter=all, numbers e.g. '1 3', a=add hosts, q=quit]:
```

Press Enter to apply to all, pick a subset by number, add hosts by hand, or quit.

## Discovery

Candidates are gathered from several places, then each is probed over key-based `ssh` (read-only, no changes). Only hosts that report a GB10 GPU / DGX Spark product name count as Sparks, and duplicates (the same Spark via alias, IP and `.local`) are merged by machine-id.

1. This machine, if it is itself a Spark (listed as `localhost`)
2. Hosts in `~/.ssh/config`
3. Unhashed, port-22 entries in `~/.ssh/known_hosts` that look local (private/CGNAT addresses, `.local`/`.lan`/`.home` names, single-label names). Internet hosts are never probed.
4. mDNS `_ssh._tcp` services on Linux (`avahi-browse`, from `avahi-utils`, if installed). Only the advertised IP is used, never the advertised name. Not available on macOS.
5. The ARP/neighbour table (multicast/broadcast excluded)
6. With `--scan` (or when nothing else is found and you say yes): a sweep of the /24 around each of your local addresses

Hosts that answer on ssh but refuse your key are skipped and counted, not touched. Host names are validated and passed to `ssh` after `--`, so a name can't be turned into an ssh option.

## Install behaviour

- Uses plain `ssh`, so your keys and `~/.ssh/config` apply. Nothing needs to be installed beforehand.
- On each Spark it writes `/etc/systemd/system/spark-gpu-clock-limit.service` (a `oneshot` unit, `WantedBy=multi-user.target`), enables it and starts it immediately, which applies `nvidia-smi -lgc 0,2200`.
- `sudo` runs over `ssh -t`, so passwordless sudo just works and a password prompt appears if a host needs one.
- Prints a result per host and a summary; exits non-zero if any host failed.
- Safe to re-run: the unit is overwritten and restarted.
- **Host keys:** discovery probes are read-only, never send a password, don't forward agents or ports, and deliberately skip host-key checking (they use no `known_hosts`) so brand-new Sparks can be found. Applying uses normal ssh checking, so for a Spark you haven't connected to before you are asked to verify its fingerprint, *before* any sudo password is sent. Verify it, or ssh to the Spark once beforehand.
- Before touching a host it checks `nvidia-smi` and applies the clocks, so a host without a working driver is left unchanged.
- The unit retries on failure (`Restart=on-failure`). Note that `systemctl stop`/`restart` of the service briefly resets the clocks (`-rgc`).

## Options

| Option | Description |
| --- | --- |
| `host ...` | Skip discovery and use these hosts (`user@host`, IPs, aliases, `localhost`) |
| `-n, --list` | Only list the Sparks found (or, with hosts given, check those), change nothing |
| `-s, --scan` | Also sweep the local /24 subnet(s) for ssh hosts |
| `-y, --yes` | Apply to everything found without asking (no terminal needed; never sweeps unless `-s` is given) |
| `-l, --user USER` | ssh user for hosts found by IP / mDNS / known_hosts |
| `-c, --clocks MIN,MAX` | Clock range in MHz (default `0,2200`) |
| `-u, --uninstall` | Disable and remove the service and reset clocks (`nvidia-smi -rgc`) |
| `-h, --help` | Show usage |

Examples:

```bash
./spark-limiter.sh -n                         # what Sparks do I have?
./spark-limiter.sh -s -l ubuntu -y            # sweep subnet, apply to all, no prompts
./spark-limiter.sh -c 0,1800 spark1 spark2    # lower cap on two specific hosts
./spark-limiter.sh --uninstall                # undo everywhere you confirm
```

## Verify

```bash
ssh spark1 'systemctl status spark-gpu-clock-limit; nvidia-smi -q -d CLOCK | grep -i -A4 "Max Clocks"'
```

After a reboot the service should be `active (exited)`.

## Requirements

- DGX Spark(s) with systemd and the NVIDIA driver
- Key-based ssh access to each Spark (otherwise it can't be discovered; you can still pass it as an explicit host)
- A user with `sudo` rights on each Spark
- `bash` on the machine you run it from (Linux or macOS; mDNS discovery is Linux-only, the other sources work on both)
- Without a terminal (cron/CI) it refuses to run unless you pass `--yes` or explicit hosts. Exits non-zero if no Sparks are found or any host fails.

## License

[MIT](LICENSE)
