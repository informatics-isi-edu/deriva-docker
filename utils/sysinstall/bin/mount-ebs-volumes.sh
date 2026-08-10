#!/usr/bin/env bash
set -euo pipefail

# EBS_MOUNTS: space-separated list of device:mountpoint:opts entries.
# Each entry is colon-delimited: /dev/nvme1n1:/data:defaults,nofail
# Multiple entries: EBS_MOUNTS="/dev/nvme1n1:/data:defaults,nofail /dev/nvme2n1:/home:defaults,nofail,usrquota"
EBS_MOUNTS="${EBS_MOUNTS:-/dev/nvme1n1:/data:defaults,nofail}"

# SWAPFILE: absolute path for a file-based swapfile (empty = disabled).
# Use this when placing swap on the root volume or a mounted EBS volume.
SWAPFILE="${SWAPFILE:-/swapfile}"

# SWAPFILE_SIZE: size passed to fallocate -l (e.g. 4G, 8G). Only used when SWAPFILE is set.
SWAPFILE_SIZE="${SWAPFILE_SIZE:-8G}"

# SWAP_DEVICE: raw block device to format and use directly as swap (empty = disabled).
# Use this for ephemeral NVMe instance store devices (e.g. /dev/nvme2n1).
SWAP_DEVICE="${SWAP_DEVICE:-}"

mkfs_if_needed() {
  local dev="$1"
  if ! blkid "$dev" >/dev/null 2>&1; then
    echo "Formatting $dev as ext4..."
    mkfs.ext4 -F "$dev"
  fi
}

ensure_fstab_entry() {
  local uuid="$1"
  local mnt="$2"
  local opts="$3"
  if ! grep -q "UUID=${uuid}  ${mnt} " /etc/fstab; then
    echo "UUID=${uuid}  ${mnt}  ext4  ${opts}  0  2" >> /etc/fstab
  fi
}

ensure_mount() {
  local dev="$1" mnt="$2" opts="$3"
  mkdir -p "$mnt"
  local uuid
  uuid=$(blkid -s UUID -o value "$dev")
  ensure_fstab_entry "$uuid" "$mnt" "$opts"
  if ! mountpoint -q "$mnt"; then
    mount "$mnt"
  fi
}

migrate_existing_into_dev() {
  local dev="$1"
  local mnt="$2"
  local tmp="/mnt/ebs-migrate-$(basename "$mnt")"

  # Only migrate if mnt is not already a mountpoint and has content
  if mountpoint -q "$mnt"; then
    echo "$mnt is already a mountpoint; skipping migration."
    return
  fi
  if [ ! -d "$mnt" ] || [ -z "$(ls -A "$mnt" 2>/dev/null || true)" ]; then
    echo "$mnt is empty or does not exist; no migration needed."
    return
  fi

  echo "Migrating existing $mnt contents into $dev via temporary mount at $tmp..."

  mkdir -p "$tmp"

  if ! mountpoint -q "$tmp"; then
    mount "$dev" "$tmp"
  fi

  rsync -aAX "$mnt"/ "$tmp"/
  sync
  umount "$tmp"

  echo "Migration of $mnt completed."
}

setup_swapfile() {
  local swapfile="$1"
  local size="$2"

  if swapon --show | awk '{print $1}' | grep -qx "$swapfile"; then
    echo "Swapfile $swapfile already active; skipping."
    return
  fi

  mkdir -p "$(dirname "$swapfile")"

  if [ -f "$swapfile" ]; then
    echo "Swapfile $swapfile exists but is not active; enabling swap."
  else
    echo "Creating swapfile $swapfile (size: $size)..."
    fallocate -l "$size" "$swapfile"
  fi

  chmod 600 "$swapfile"
  mkswap "$swapfile"
  swapon "$swapfile"

  if ! grep -qE "^${swapfile}[[:space:]]" /etc/fstab; then
    echo "$swapfile  none  swap  sw  0  0" >> /etc/fstab
  fi
}

setup_swap_device() {
  local dev="$1"

  if ! [[ -b "$dev" ]]; then
    echo "Swap device $dev not found; skipping device swap setup."
    return
  fi

  if swapon --show | awk '{print $1}' | grep -qx "$dev"; then
    echo "Swap device $dev already active; skipping."
    return
  fi

  echo "Configuring $dev as swap device..."
  mkswap "$dev"
  swapon "$dev"

  local uuid
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null || true)
  if [[ -n "$uuid" ]]; then
    if ! grep -qE "UUID=${uuid}[[:space:]]" /etc/fstab; then
      echo "UUID=${uuid}  none  swap  sw  0  0" >> /etc/fstab
    fi
  else
    if ! grep -qE "^${dev}[[:space:]]" /etc/fstab; then
      echo "$dev  none  swap  sw  0  0" >> /etc/fstab
    fi
  fi
}

# --- Main ---

echo "Preparing EBS mounts..."

for entry in $EBS_MOUNTS; do
  dev="${entry%%:*}"; rest="${entry#*:}"; mnt="${rest%%:*}"; opts="${rest#*:}"
  mkfs_if_needed "$dev"
  migrate_existing_into_dev "$dev" "$mnt"
  ensure_mount "$dev" "$mnt" "$opts"
done

if [[ -n "$SWAPFILE" ]]; then
  setup_swapfile "$SWAPFILE" "$SWAPFILE_SIZE"
fi

if [[ -n "$SWAP_DEVICE" ]]; then
  setup_swap_device "$SWAP_DEVICE"
fi

echo "Current mounts:"
for entry in $EBS_MOUNTS; do
  rest="${entry#*:}"; mnt="${rest%%:*}"
  df -h "$mnt" 2>/dev/null || true
done

echo "Current swap:"
swapon --show || true