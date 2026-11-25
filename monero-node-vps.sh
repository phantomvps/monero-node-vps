#!/usr/bin/env bash
# monero-node-vps.sh - run your own Monero node (monerod) as a systemd service on an Ubuntu / Debian VPS.
#
# What it does:
#   1. Downloads hashes.txt from getmonero.org and checks its GPG signature against binaryFate's key
#      (fetched from the monero-project repo and pinned by fingerprint). Any mismatch stops the script.
#   2. Downloads the official monerod release from downloads.getmonero.org and checks its SHA256
#      against the signed hashes.txt. Any mismatch stops the script; nothing is installed.
#   3. Creates a 'monero' system user, /etc/monerod.conf and the monerod systemd service.
#   4. Pruned node by default (about 1/3 of the disk); --full keeps the whole blockchain.
#   5. --public-rpc opens a restricted (view-only) RPC on port 18089 for your wallets.
#   6. If ufw is active, opens 18080/tcp (P2P) and 18089/tcp with --public-rpc.
#   Running it again upgrades monerod to the newest release and keeps the blockchain.
#
# Usage:  sudo bash monero-node-vps.sh [--pruned | --full] [--public-rpc] [--tarball FILE] [--no-start] [--yes]
#   --tarball FILE  use a release file you already downloaded (it is still checked against the signed hashes)
#   --no-start      install and configure, but do not start monerod
# Tested on Ubuntu 22.04 and 24.04 (see .github/workflows/test.yml); written for Debian 12 / 13 too.
# License: MIT. Maintained by the PhantomVPS team - https://phantomvps.com
set -euo pipefail

HASHES_URL="https://www.getmonero.org/downloads/hashes.txt"
KEY_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc"
KEY_FPR="81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92"   # binaryFate, signs the Monero release hashes
DL_BASE="https://downloads.getmonero.org/cli"
OPT=/opt/monero; DATA=/var/lib/monero; LOGDIR=/var/log/monero; CONF=/etc/monerod.conf
UNIT=/etc/systemd/system/monerod.service

MODE=pruned; PUBLIC=0; TARBALL=""; NO_START=0; ASSUME_YES=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pruned) MODE=pruned; shift ;;
    --full) MODE=full; shift ;;
    --public-rpc) PUBLIC=1; shift ;;
    --tarball) [ -n "${2:-}" ] || die "--tarball needs a file"; TARBALL="$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || die "--tarball file not found: $TARBALL"
  TARBALL="$(readlink -f "$TARBALL")"
fi
[ "$(id -u)" -eq 0 ] || die "run as root (sudo bash $0)"
[ -r /etc/os-release ] || die "cannot read /etc/os-release"
OS_ID="$(. /etc/os-release && echo "${ID:-}")"
case "$OS_ID" in ubuntu|debian) ;; *) die "only Ubuntu and Debian are supported (found: ${OS_ID:-unknown})" ;; esac
case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64) ARCH=armv8 ;;
  *) die "unsupported CPU architecture: $(uname -m) (x86_64 and aarch64 only)" ;;
esac

# A pruned database cannot be turned back into a full one.
if [ "$MODE" = full ] && [ -f "$CONF" ] && grep -q '^prune-blockchain=1' "$CONF" && [ -d "$DATA/lmdb" ]; then
  die "this node already has a pruned blockchain in $DATA/lmdb; --full would need a fresh sync (move that folder away first)"
fi

need_gb=95; [ "$MODE" = full ] && need_gb=260
free_gb=$(( $(df -Pk "$(dirname "$DATA")" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
echo "Plan: monerod ($MODE node), public restricted RPC on 18089: $([ "$PUBLIC" -eq 1 ] && echo yes || echo no), start now: $((1-NO_START))"
echo "      data in $DATA - needs about ${need_gb} GB and grows; free now: ${free_gb} GB. An SSD is strongly recommended."
[ "$free_gb" -ge "$need_gb" ] || warn "not enough free disk for a fully synced $MODE node (the sync will stop when the disk is full)"
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Continue? [y/N] " a; case "$a" in y|Y|yes) ;; *) echo "Aborted."; exit 1 ;; esac
fi

export DEBIAN_FRONTEND=noninteractive
info "Installing tools (curl, gnupg, bzip2)"
apt-get update -q
apt-get -y -q install curl ca-certificates gnupg bzip2

WORK="$(mktemp -d)"; export GNUPGHOME="$WORK/gnupg"
trap 'gpgconf --kill all >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
install -d -m 700 "$GNUPGHOME"

info "Checking the signature of hashes.txt"
curl -fsSL --proto '=https' --retry 3 -o "$WORK/binaryfate.asc" "$KEY_URL"
curl -fsSL --proto '=https' --retry 3 -o "$WORK/hashes.txt" "$HASHES_URL"
gpg --batch --quiet --import "$WORK/binaryfate.asc" 2>/dev/null
gpg --batch --with-colons --fingerprint "$KEY_FPR" 2>/dev/null | grep "^fpr:::::::::$KEY_FPR:" >/dev/null \
  || die "the downloaded key is not binaryFate's key ($KEY_FPR)"
# Decrypt = verify + write out ONLY the signed text, so unsigned lines added around it are ignored.
gpg --batch --status-fd 3 --output "$WORK/hashes.signed" --decrypt "$WORK/hashes.txt" 3> "$WORK/gpg.status" 2>/dev/null \
  || die "GPG signature check of hashes.txt FAILED"
awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" {print $NF}' "$WORK/gpg.status" | grep -x "$KEY_FPR" >/dev/null \
  || die "hashes.txt is not signed by binaryFate ($KEY_FPR)"
info "Signature OK (binaryFate, $KEY_FPR)"

line="$(grep -E "^[0-9a-f]{64}  monero-linux-$ARCH-v[0-9.]+\.tar\.bz2\$" "$WORK/hashes.signed" || true)"
[ "$(printf '%s\n' "$line" | grep -c .)" -eq 1 ] || die "could not find exactly one monero-linux-$ARCH entry in hashes.txt"
WANT_SHA="${line%%  *}"; FILE="${line##*  }"
VERSION="$(echo "$FILE" | sed -E 's/^monero-linux-[a-z0-9]+-(v[0-9.]+)\.tar\.bz2$/\1/')"
info "Newest release: $VERSION ($FILE)"

if [ -x "$OPT/$VERSION/monerod" ]; then
  info "monerod $VERSION is already installed in $OPT/$VERSION (kept)"
else
  if [ -n "$TARBALL" ]; then
    info "Using $TARBALL"
    cp "$TARBALL" "$WORK/$FILE"
  else
    info "Downloading $DL_BASE/$FILE"
    curl -fSL --proto '=https' --retry 3 -o "$WORK/$FILE" "$DL_BASE/$FILE"
  fi
  GOT_SHA="$(sha256sum "$WORK/$FILE" | awk '{print $1}')"
  [ "$GOT_SHA" = "$WANT_SHA" ] || die "SHA256 MISMATCH for $FILE: expected $WANT_SHA, got $GOT_SHA. Nothing was installed."
  info "SHA256 OK"
  install -d -m 755 "$OPT"
  rm -rf "$OPT/.new"; install -d -m 755 "$OPT/.new"
  tar -xjf "$WORK/$FILE" -C "$OPT/.new" --strip-components=1 --no-same-owner
  [ -x "$OPT/.new/monerod" ] || die "monerod not found in the release archive"
  mv "$OPT/.new" "$OPT/$VERSION"
fi
ln -sfn "$OPT/$VERSION" "$OPT/current"
"$OPT/current/monerod" --version

if id monero >/dev/null 2>&1; then
  info "User monero exists"
else
  info "Creating system user monero"
  useradd --system --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin monero
fi
install -d -m 750 -o monero -g monero "$DATA" "$LOGDIR"

new_conf="$WORK/monerod.conf"
{
  echo "# Managed by monero-node-vps.sh - re-run the script to change these settings."
  echo "data-dir=$DATA"
  echo "log-file=$LOGDIR/monerod.log"
  echo "log-level=0"
  echo "max-log-files=5"
  echo "max-log-file-size=10485760"
  echo "p2p-bind-ip=0.0.0.0"
  echo "p2p-bind-port=18080"
  echo "rpc-bind-ip=127.0.0.1"
  echo "rpc-bind-port=18081"
  echo "no-igd=1"
  echo "enable-dns-blocklist=1"
  if [ "$MODE" = pruned ]; then echo "prune-blockchain=1"; echo "sync-pruned-blocks=1"; fi
  if [ "$PUBLIC" -eq 1 ]; then
    echo "rpc-restricted-bind-ip=0.0.0.0"
    echo "rpc-restricted-bind-port=18089"
    echo "public-node=1"
  fi
} > "$new_conf"
CHANGED=0
if ! cmp -s "$new_conf" "$CONF" 2>/dev/null; then
  install -m 644 "$new_conf" "$CONF"; CHANGED=1; info "Wrote $CONF"
else
  info "$CONF unchanged"
fi

new_unit="$WORK/monerod.service"
cat > "$new_unit" <<EOF
# Managed by monero-node-vps.sh
[Unit]
Description=Monero node (monerod)
After=network-online.target
Wants=network-online.target

[Service]
User=monero
Group=monero
Type=simple
ExecStart=$OPT/current/monerod --config-file=$CONF --non-interactive
Restart=on-failure
RestartSec=30
TimeoutStopSec=180
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
if ! cmp -s "$new_unit" "$UNIT" 2>/dev/null; then
  install -m 644 "$new_unit" "$UNIT"; CHANGED=1; systemctl daemon-reload; info "Wrote $UNIT"
fi
systemctl enable monerod >/dev/null 2>&1

if ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then   # no -q: avoids SIGPIPE + pipefail
  info "ufw is active: allowing 18080/tcp (P2P)"
  ufw allow 18080/tcp comment 'monerod p2p'
  if [ "$PUBLIC" -eq 1 ]; then
    ufw allow 18089/tcp comment 'monerod restricted rpc'
  else
    ufw delete allow 18089/tcp >/dev/null 2>&1 || true
  fi
fi

if [ "$NO_START" -eq 1 ]; then
  info "--no-start: monerod is installed and enabled but not started (start it: systemctl start monerod)"
elif systemctl is-active --quiet monerod; then
  running="$(readlink -f "/proc/$(systemctl show -p MainPID --value monerod)/exe" 2>/dev/null || true)"
  if [ "$CHANGED" -eq 1 ] || [ "$running" != "$OPT/$VERSION/monerod" ]; then
    info "Restarting monerod (new version or settings)"; systemctl restart monerod
  else
    info "monerod is running $VERSION, nothing to restart"
  fi
else
  info "Starting monerod"; systemctl start monerod
fi

# keep the two newest versions, remove older ones
mapfile -t old < <(find "$OPT" -mindepth 1 -maxdepth 1 -type d -name 'v*' -printf '%f\n' | sort -V | head -n -2)
for v in "${old[@]}"; do
  if [ "$v" != "$VERSION" ]; then rm -rf "${OPT:?}/$v"; info "Removed old version $v"; fi
done

echo
info "Done. The first sync takes from several hours to a few days."
info "Progress:   journalctl -u monerod -f     or     tail -f $LOGDIR/monerod.log"
info "Status:     curl -s http://127.0.0.1:18081/get_info | grep -E '\"(height|target_height|synchronized)\"'"
[ "$PUBLIC" -eq 1 ] && info "Wallets:    point your wallet to THIS_SERVER_IP:18089 (restricted, view-only RPC)"
exit 0
