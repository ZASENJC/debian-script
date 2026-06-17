#!/usr/bin/env bash
# SMB mount manager for Debian/Ubuntu.
# Usage: sudo bash smb-mount.sh

set -Eeuo pipefail
umask 077

MARK_BEGIN="# smb-mount BEGIN"
MARK_END="# smb-mount END"
FSTAB_FILE="${SMB_FSTAB_FILE:-/etc/fstab}"
CRED_PREFIX="${SMB_CRED_PREFIX:-/root/.smbcredentials}"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行：sudo bash $0" >&2
    exit 1
  fi
}

ensure_cifs_utils() {
  command -v mount.cifs >/dev/null 2>&1 && return 0
  command -v apt-get >/dev/null 2>&1 || {
    echo "未找到 mount.cifs。请先安装 cifs-utils。" >&2
    exit 1
  }
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cifs-utils
}

ask_required() {
  local prompt="$1" value
  while true; do
    read -r -p "$prompt" value
    [ -n "$value" ] && printf '%s' "$value" && return 0
    echo "不能为空。"
  done
}

ask_default() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default] " value
  printf '%s' "${value:-$default}"
}

confirm() {
  local prompt="$1" default="$2" answer suffix="[y/N]"
  [ "$default" = "y" ] && suffix="[Y/n]"
  read -r -p "$prompt $suffix " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

valid_share() {
  [[ "$1" =~ ^//[^/[:space:]]+/.+[^[:space:]]$ ]]
}

valid_mountpoint() {
  [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [ "$1" != "/" ] && [[ "$1" != *"//"* ]] && [[ "$1" != *"/../"* ]] && [[ "$1" != *"/.." ]]
}

safe_name() {
  printf '%s' "$1" | sed 's#^/##; s#[^A-Za-z0-9._-]#_#g; s#_*$##'
}

fstab_escape() {
  printf '%s' "$1" | sed 's#\\#\\\\#g; s# #\\040#g; s#	#\\011#g'
}

backup_fstab() {
  cp -a -- "$FSTAB_FILE" "${FSTAB_FILE}.bak.$(date +%Y%m%d%H%M%S)"
}

fstab_mountpoint_exists() {
  grep -Fqs " $(fstab_escape "$1") " "$FSTAB_FILE"
}

remove_fstab_block() {
  local mountpoint="$1" tmp
  tmp="$(mktemp)"
  backup_fstab
  awk -v begin="$MARK_BEGIN $mountpoint" -v end="$MARK_END $mountpoint" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "$FSTAB_FILE" >"$tmp"
  cat "$tmp" >"$FSTAB_FILE"
  rm -f "$tmp"
}

default_owner() {
  local name="${SUDO_USER:-}"
  [ -n "$name" ] && [ "$name" != "root" ] || name="$(logname 2>/dev/null || true)"
  printf '%s' "${name:-root}"
}

add_mount() {
  local share mountpoint owner uid gid smb_user smb_pass smb_domain
  local smb_version access_mode seal_mode mode_pair dir_mode file_mode name cred options

  ensure_cifs_utils
  echo
  echo "增加 SMB 挂载"

  share="$(ask_required "SMB 路径，例如 //192.168.1.10/media: ")"
  valid_share "$share" || { echo "SMB 路径格式不正确。" >&2; return 1; }

  mountpoint="$(ask_required "本地挂载点，例如 /mnt/nas/media: ")"
  valid_mountpoint "$mountpoint" || { echo "挂载点必须是无空格的安全绝对路径。" >&2; return 1; }

  mountpoint -q "$mountpoint" 2>/dev/null && { echo "$mountpoint 已经是挂载点。" >&2; return 1; }
  fstab_mountpoint_exists "$mountpoint" && { echo "$FSTAB_FILE 已有 $mountpoint 条目。" >&2; return 1; }

  owner="$(ask_default "本地文件归属用户" "$(default_owner)")"
  id "$owner" >/dev/null 2>&1 || { echo "找不到本地用户：$owner" >&2; return 1; }
  uid="$(id -u "$owner")"
  gid="$(id -g "$owner")"

  smb_user="$(ask_required "SMB 用户名: ")"
  read -r -s -p "SMB 密码: " smb_pass
  echo
  read -r -p "SMB 域/工作组，可留空: " smb_domain

  smb_version="$(ask_default "SMB 版本" "3.1.1")"
  case "$smb_version" in
    3.1.1|3.0|2.1|2.0) ;;
    *) echo "SMB 版本仅允许 3.1.1、3.0、2.1、2.0。" >&2; return 1 ;;
  esac

  if confirm "是否只读挂载？安全建议选只读。" "y"; then
    access_mode="ro"
  else
    access_mode="rw"
  fi

  if confirm "是否启用 SMB 加密 seal？NAS 支持时再开启。" "n"; then
    seal_mode="seal"
  else
    seal_mode=""
  fi

  mode_pair="$(ask_default "权限模式，格式为 目录权限,文件权限" "0750,0640")"
  [[ "$mode_pair" =~ ^[0-7]{3,4},[0-7]{3,4}$ ]] || { echo "权限模式格式不正确。" >&2; return 1; }
  dir_mode="${mode_pair%,*}"
  file_mode="${mode_pair#*,}"

  name="$(safe_name "$mountpoint")"
  [ -n "$name" ] || { echo "无法生成凭据文件名。" >&2; return 1; }
  cred="$CRED_PREFIX-$name"

  if [ -e "$cred" ]; then
    echo "凭据文件已存在：$cred" >&2
    echo "为避免覆盖或误删已有凭据，请先删除旧挂载或手动清理该文件。" >&2
    return 1
  fi

  {
    printf 'username=%s\n' "$smb_user"
    printf 'password=%s\n' "$smb_pass"
    [ -n "$smb_domain" ] && printf 'domain=%s\n' "$smb_domain"
  } >"$cred"
  chmod 600 "$cred"

  install -d -m 0755 "$mountpoint"
  options="credentials=$cred,vers=$smb_version,iocharset=utf8,uid=$uid,gid=$gid,dir_mode=$dir_mode,file_mode=$file_mode,nosuid,nodev,noexec,noserverino,$access_mode,_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600"
  [ -n "$seal_mode" ] && options="$options,$seal_mode"

  echo "正在测试挂载..."
  if ! mount -t cifs "$share" "$mountpoint" -o "$options"; then
    rm -f "$cred"
    echo "挂载测试失败，已删除凭据文件。" >&2
    return 1
  fi

  if ! umount "$mountpoint"; then
    rm -f "$cred"
    echo "临时卸载失败，请检查是否有进程占用 $mountpoint。" >&2
    return 1
  fi

  backup_fstab
  {
    printf '%s %s\n' "$MARK_BEGIN" "$mountpoint"
    printf '%s %s cifs %s 0 0\n' "$(fstab_escape "$share")" "$(fstab_escape "$mountpoint")" "$options"
    printf '%s %s\n' "$MARK_END" "$mountpoint"
  } >>"$FSTAB_FILE"

  systemctl daemon-reload >/dev/null 2>&1 || true
  if ! mount "$mountpoint"; then
    remove_fstab_block "$mountpoint"
    rm -f "$cred"
    echo "最终挂载失败，已回滚 fstab 和凭据文件。" >&2
    return 1
  fi

  echo "完成：$share -> $mountpoint"
  echo "凭据：$cred"
}

list_managed() {
  awk -v begin="$MARK_BEGIN" 'index($0, begin " ") == 1 { sub(begin " ", ""); print }' "$FSTAB_FILE"
}

delete_mount() {
  local entries count choice mountpoint cred

  echo
  echo "删除 SMB 挂载"
  entries="$(list_managed)"
  [ -n "$entries" ] || { echo "没有找到本脚本创建的挂载。"; return 0; }

  printf '%s\n' "$entries" | nl -w2 -s") "
  read -r -p "选择要删除的序号: " choice
  count="$(printf '%s\n' "$entries" | wc -l | tr -d ' ')"
  [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || { echo "序号无效。" >&2; return 1; }

  mountpoint="$(printf '%s\n' "$entries" | sed -n "${choice}p")"
  confirm "确认卸载并删除 $mountpoint ?" "n" || { echo "已取消。"; return 0; }

  if mountpoint -q "$mountpoint" 2>/dev/null && ! umount "$mountpoint"; then
    echo "卸载失败，可能有进程正在占用 $mountpoint。" >&2
    echo "可运行：sudo fuser -vm '$mountpoint'" >&2
    return 1
  fi

  cred="$(awk -v begin="$MARK_BEGIN $mountpoint" -v end="$MARK_END $mountpoint" '
    $0 == begin { inside=1; next }
    $0 == end { inside=0; next }
    inside && $3 == "cifs" {
      n=split($4, parts, ",")
      for (i=1; i<=n; i++) if (parts[i] ~ /^credentials=/) {
        sub(/^credentials=/, "", parts[i]); print parts[i]; exit
      }
    }
  ' "$FSTAB_FILE")"

  remove_fstab_block "$mountpoint"
  case "$cred" in "$CRED_PREFIX"-*) rm -f "$cred" ;; esac
  systemctl daemon-reload >/dev/null 2>&1 || true

  if confirm "是否删除空挂载目录 $mountpoint ?" "n"; then
    rmdir "$mountpoint" 2>/dev/null || echo "目录非空，保留：$mountpoint"
  fi

  echo "已删除：$mountpoint"
}

main_menu() {
  local choice
  while true; do
    echo
    echo "SMB 挂载管理"
    echo "1) 增加挂载"
    echo "2) 删除/卸载"
    echo "q) 退出"
    read -r -p "请选择: " choice
    case "$choice" in
      1) add_mount ;;
      2) delete_mount ;;
      q|Q) exit 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

main() {
  need_root
  main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
