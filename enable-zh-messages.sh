#!/usr/bin/env bash
set -euo pipefail

backup_file() {
  local src="$1"
  local suffix
  suffix="$(date +%Y%m%d%H%M%S)"
  cp -a -- "$src" "$src.bak.$suffix"
}

# Require root
if [ "$(id -u)" -ne 0 ]; then
  exec sudo env DEBIAN_FRONTEND=noninteractive bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive

CONFIGURE_SSH=0
while [ "${1:-}" != "" ]; do
  case "$1" in
    --configure-ssh)
      CONFIGURE_SSH=1
      shift
      ;;
    --no-configure-ssh)
      CONFIGURE_SSH=0
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

echo "[1/7] apt update & install prerequisites..."
apt-get update -y
apt-get install -y --no-install-recommends locales man-db

echo "[2/7] Ensure locales en_US.UTF-8 and zh_CN.UTF-8 are generated..."
if [ -e /etc/locale.gen ]; then
  backup_file /etc/locale.gen
else
  touch /etc/locale.gen
fi
grep -qE "^[[:space:]]*en_US\.UTF-8[[:space:]]+UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
grep -qE "^[[:space:]]*zh_CN\.UTF-8[[:space:]]+UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
sed -ri "s/^[#[:space:]]*(en_US\.UTF-8[[:space:]]+UTF-8)/\1/" /etc/locale.gen
sed -ri "s/^[#[:space:]]*(zh_CN\.UTF-8[[:space:]]+UTF-8)/\1/" /etc/locale.gen

locale-gen en_US.UTF-8 zh_CN.UTF-8

echo "[3/7] Set message locale to Chinese only..."
update-locale LANG=en_US.UTF-8 LC_MESSAGES=zh_CN.UTF-8 LANGUAGE=zh_CN:zh

echo "[4/7] Persist for shells and PAM..."
if [ -e /etc/environment ]; then
  backup_file /etc/environment
else
  touch /etc/environment
fi
cat >/etc/profile.d/zz-lc-messages-zh.sh << "EOF"
export LC_MESSAGES=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
EOF
chmod 0644 /etc/profile.d/zz-lc-messages-zh.sh

grep -q "^LC_MESSAGES=" /etc/environment \
  && sed -ri "s/^LC_MESSAGES=.*/LC_MESSAGES=zh_CN.UTF-8/" /etc/environment \
  || echo "LC_MESSAGES=zh_CN.UTF-8" >> /etc/environment

grep -q "^LANGUAGE=" /etc/environment \
  && sed -ri "s/^LANGUAGE=.*/LANGUAGE=zh_CN:zh/" /etc/environment \
  || echo "LANGUAGE=zh_CN:zh" >> /etc/environment

echo "[5/7] Install Chinese manpages (best effort)..."
if ! apt-get install -y --no-install-recommends manpages-zh; then
  echo "Warning: manpages-zh could not be installed; continuing without Chinese manpages." >&2
fi

echo "[6/7] SSH AcceptEnv (optional; pass --configure-ssh to enable)..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ "$CONFIGURE_SSH" -eq 1 ] && [ -f "$SSHD_CFG" ]; then
  backup_file "$SSHD_CFG"
  if ! grep -qE "^[[:space:]]*AcceptEnv.*(LANG|LC_|LANGUAGE)" "$SSHD_CFG"; then
    echo "AcceptEnv LANG LC_* LANGUAGE" >> "$SSHD_CFG"
  fi

  sshd -t -f "$SSHD_CFG"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  else
    service ssh restart 2>/dev/null || service sshd restart 2>/dev/null || true
  fi
fi

echo "[7/7] Done. Open a new shell or re-login."
