# monero-node-vps

One readable script that installs and runs your own **Monero node** (`monerod`) as a systemd service on an
**Ubuntu or Debian VPS**. The release is downloaded from getmonero.org and **verified before anything is
installed**: GPG signature of the hash list, then SHA256 of the file. Any mismatch stops the script.

```bash
curl -fsSLO https://raw.githubusercontent.com/phantomvps/monero-node-vps/main/monero-node-vps.sh
less monero-node-vps.sh            # read it first: it is short
sudo bash monero-node-vps.sh --public-rpc
```

Why run your own node: your wallet talks to a node you control instead of a stranger's remote node, and you help
the Monero network with another well-connected peer.

## What it does

| Step | Details |
|---|---|
| Verify | downloads `hashes.txt` from getmonero.org and binaryFate's key from the monero-project repo; the key must have fingerprint `81AC 591F E9C4 B65C 5806 AFC3 F0AF 4D46 2A0B DF92` and must have signed `hashes.txt`. Only the signed text is used. |
| Download | the newest `monero-linux-x64` (or `armv8`) release from downloads.getmonero.org; its SHA256 must match the signed list |
| Install | `/opt/monero/<version>/`, with `/opt/monero/current` pointing to the active version; the two newest versions are kept |
| User | `monero` system user without a login shell; data in `/var/lib/monero`, logs in `/var/log/monero` |
| Config | `/etc/monerod.conf`: P2P on 18080, full RPC on `127.0.0.1:18081` only, pruned by default |
| Service | `monerod.service` (systemd, restarts on failure, basic hardening), enabled at boot and started |
| Firewall | if `ufw` is active: opens 18080/tcp, and 18089/tcp with `--public-rpc` (closes it again without) |

**Running it again upgrades** monerod to the newest release (verified the same way) and restarts it only if the
version or settings changed. The blockchain stays.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--pruned` | yes | keep about 1/3 of the blockchain (well under half the size of a full node; check the current size before you pick a disk); fully validates, serves wallets normally |
| `--full` | | keep the whole blockchain (over 200 GB and growing every day); refused on top of an existing pruned database |
| `--public-rpc` | off | restricted (view-only) RPC on `0.0.0.0:18089` for your wallets, advertised as a public node |
| `--tarball FILE` | | use a release file you already downloaded; it is still checked against the signed hashes |
| `--no-start` | off | install and configure, but do not start monerod |
| `--yes` | off | do not ask for confirmation |

## Safety notes

- The script **fails closed**: a bad signature, a wrong key fingerprint or a wrong SHA256 stops it before
  anything is installed or changed.
- The full RPC (18081, with admin commands) listens on localhost only. `--public-rpc` exposes only the
  restricted RPC, which cannot stop the node or change its settings. Anyone who knows your IP can use it as a
  remote node; leave it off if you only need it yourself (use an SSH tunnel to 18081 instead).
- The first sync takes from several hours to a few days and needs a lot of disk I/O: an SSD/NVMe disk and
  at least 4 GB RAM are strongly recommended. The script warns if free disk space looks too small.
- Progress: `journalctl -u monerod -f` or
  `curl -s http://127.0.0.1:18081/get_info | grep -E '"(height|target_height|synchronized)"'`.

## Tested on

Every push runs on GitHub Actions on **Ubuntu 22.04 and 24.04**: a tampered release file is refused (after the
real signature check of `hashes.txt`) and nothing is installed; then the real release is downloaded, verified
and installed; user, config, systemd unit and ufw rules are checked; a second run must not download again or
change anything; `--full` over a pruned database is refused; monerod is started for a short time to check that
both RPC ports answer, then stopped. A full blockchain sync is not run in CI. Debian 12 / 13 are supported by
the script but not tested in CI.

## Need a server?

Maintained by the team behind [PhantomVPS](https://phantomvps.com?ref=github): VPS and dedicated servers with root access,
no ID documents, paid with Monero, Bitcoin, Litecoin, USDT, USDC, SOL or TRX.
See [VPS for a Monero node](https://phantomvps.com/monero-node-vps?ref=github).

## License

MIT
