#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd -P)"
script="$repo_root/smb-mount.sh"

fail() {
  printf 'smb-mount check failed: %s\n' "$*" >&2
  exit 1
}

bash -n "$script"

grep -q 'umask 077' "$script" \
  || fail 'credentials should be created under restrictive umask'

grep -q 'chmod 600 "$cred"' "$script" \
  || fail 'credential file should be chmod 600'

grep -q 'credentials=$cred' "$script" \
  || fail 'fstab should reference credential file instead of inline password'

grep -q 'nosuid,nodev,noexec' "$script" \
  || fail 'mount options should include nosuid,nodev,noexec'

grep -q '_netdev,nofail,x-systemd.automount' "$script" \
  || fail 'mount options should be boot-safe'

grep -q 'backup_fstab' "$script" \
  || fail 'script should back up /etc/fstab before editing'

grep -q 'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cifs-utils' "$script" \
  || fail 'cifs-utils install should be noninteractive and minimal'

grep -q 'case "$cred" in "$CRED_PREFIX"-\*) rm -f "$cred"' "$script" \
  || fail 'delete should only remove script-owned credential files'

grep -q 'if \[\[ "${BASH_SOURCE\[0\]}" == "$0" \]\]; then' "$script" \
  || fail 'script should be source-safe for tests'

if grep -q 'sudo -E' "$script"; then
  fail 'script must not preserve full caller environment via sudo -E'
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export SMB_FSTAB_FILE="$tmp/fstab"
export SMB_CRED_PREFIX="$tmp/.smbcredentials"
: >"$SMB_FSTAB_FILE"
source "$script"

valid_share '//nas/media' || fail 'valid_share should accept //host/share'
valid_share '//192.168.1.10/media' || fail 'valid_share should accept IPv4 server paths'
if valid_share '/nas/media'; then fail 'valid_share should reject local-looking paths'; fi
if valid_share '//nas'; then fail 'valid_share should reject missing share name'; fi
if valid_share '//nas/ '; then fail 'valid_share should reject trailing whitespace'; fi

valid_mountpoint '/mnt/nas/media' || fail 'valid_mountpoint should accept safe absolute paths'
if valid_mountpoint '/'; then fail 'valid_mountpoint should reject /'; fi
if valid_mountpoint 'mnt/nas'; then fail 'valid_mountpoint should reject relative paths'; fi
if valid_mountpoint '/mnt/with space'; then fail 'valid_mountpoint should reject spaces'; fi
if valid_mountpoint '/mnt/unsafe;rm'; then fail 'valid_mountpoint should reject shell metacharacters'; fi
if valid_mountpoint '/mnt/../etc'; then fail 'valid_mountpoint should reject traversal'; fi

[ "$(safe_name '/mnt/nas/media')" = 'mnt_nas_media' ] \
  || fail 'safe_name should normalize mount path'

[ "$(fstab_escape '/mnt/with space')" = '/mnt/with\040space' ] \
  || fail 'fstab_escape should escape spaces'



sim_bin="$tmp/bin"
mount_state="$tmp/mount-state"
mount_log="$tmp/mount.log"
mkdir -p "$sim_bin" "$tmp/work"
: >"$mount_state"
: >"$mount_log"
export SMB_TEST_MOUNT_STATE="$mount_state"
export SMB_TEST_MOUNT_LOG="$mount_log"

cat >"$sim_bin/mount.cifs" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat >"$sim_bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat >"$sim_bin/mountpoint" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${SMB_TEST_MOUNT_STATE:?}"
if [ "${1:-}" = "-q" ]; then
  shift
fi
grep -Fxq -- "$1" "$state"
FAKE

cat >"$sim_bin/mount" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${SMB_TEST_MOUNT_STATE:?}"
log="${SMB_TEST_MOUNT_LOG:?}"
printf 'mount %s\n' "$*" >>"$log"
if [ "${1:-}" = "-t" ]; then
  mp="$4"
else
  mp="$1"
fi
grep -Fxq -- "$mp" "$state" || printf '%s\n' "$mp" >>"$state"
FAKE

cat >"$sim_bin/umount" <<'FAKE'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${SMB_TEST_MOUNT_STATE:?}"
log="${SMB_TEST_MOUNT_LOG:?}"
printf 'umount %s\n' "$*" >>"$log"
mp="${1:-}"
grep -Fxv -- "$mp" "$state" >"$state.tmp" || true
mv "$state.tmp" "$state"
FAKE

chmod +x "$sim_bin/"*
PATH="$sim_bin:$PATH"

mount_dir="$tmp/work/mnt"
add_input=$'//nas/share\n'"$mount_dir"$'\nroot\nuser1\npass1\nWORKGROUP\n3.1.1\ny\nn\n0750,0640\n'
printf '%b' "$add_input" | add_mount >/dev/null

grep -q '# smb-mount BEGIN' "$SMB_FSTAB_FILE" || fail 'fstab block marker missing'
grep -q 'nosuid,nodev,noexec' "$SMB_FSTAB_FILE" || fail 'fstab options missing hardening flags'
grep -q '_netdev,nofail,x-systemd.automount' "$SMB_FSTAB_FILE" || fail 'fstab options missing boot safety flags'

cred_file="$SMB_CRED_PREFIX-$(safe_name "$mount_dir")"
[ -f "$cred_file" ] || fail 'credential file was not created'
grep -q '^username=user1$' "$cred_file" || fail 'credential file missing username'
grep -q '^password=pass1$' "$cred_file" || fail 'credential file missing password'
grep -q '^domain=WORKGROUP$' "$cred_file" || fail 'credential file missing domain'

grep -q "mount -t cifs //nas/share" "$mount_log" || fail 'mount should be attempted'
grep -q "umount $mount_dir" "$mount_log" || fail 'temporary unmount should be attempted'

delete_input=$'1\ny\nn\n'
printf '%b' "$delete_input" | delete_mount >/dev/null

[ ! -s "$SMB_FSTAB_FILE" ] || fail 'fstab block should be removed after delete'
[ ! -e "$cred_file" ] || fail 'credential file should be removed after delete'
if grep -Fxq -- "$mount_dir" "$mount_state"; then
  fail 'mount state should be cleared after delete'
fi

printf 'smb-mount checks passed\n'
