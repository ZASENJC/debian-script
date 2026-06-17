#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
script="$repo_root/enable-zh-messages.sh"

fail() {
  printf 'hardening check failed: %s\n' "$*" >&2
  exit 1
}

bash -n "$script"

if grep -q 'sudo -E' "$script"; then
  fail 'sudo re-exec must not preserve the full caller environment'
fi

grep -q 'sudo env DEBIAN_FRONTEND=noninteractive' "$script" \
  || fail 'sudo re-exec should use a constrained environment'

grep -q 'CONFIGURE_SSH=0' "$script" \
  || fail 'SSH daemon config changes should be opt-in by default'

grep -q -- '--configure-ssh' "$script" \
  || fail 'script should expose an explicit flag for SSH config changes'

grep -q 'sshd -t -f "$SSHD_CFG"' "$script" \
  || fail 'script should validate sshd_config before restarting ssh'

grep -q 'backup_file /etc/locale.gen' "$script" \
  || fail 'script should back up /etc/locale.gen before editing'

grep -q 'backup_file /etc/environment' "$script" \
  || fail 'script should back up /etc/environment before editing'

if grep -Eq 'apt-get install .+\|\| true' "$script"; then
  fail 'required apt package installation should not be silently ignored'
fi

printf 'hardening checks passed\n'
