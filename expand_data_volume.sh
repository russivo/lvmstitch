#!/usr/bin/env bash
# ----------------------------------------------------------------------
# expand_data_volume.sh
#
# PURPOSE
#   • Detect any newly‑attached “blank” disks on a remote VM.
#   • Add them as LVM physical volumes to the VG that already contains
#     the LV mounted on /data.
#   • Grow the LV to consume all free space in the VG.
#   • Resize the ext4 filesystem so the extra space appears under /data.
#
# USAGE
#   ./expand_data_volume.sh <ssh_user> <vm_ip> <ssh_private_key>
#
#   <ssh_user>          SSH user (must have password‑less sudo)
#   <vm_ip>             IP address or hostname of the target VM
#   <ssh_private_key>   Path to the SSH private key (read‑only)
#
# PREREQUISITES ON THE REMOTE VM
#   • sudo access without a password prompt for the supplied SSH user
#   • Packages: lvm2, util‑linux (lsblk, blkid), e2fsprogs (resize2fs)
# ----------------------------------------------------------------------

set -euo pipefail

# ---------- Helper functions ----------
die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $0 <ssh_user> <vm_ip> <ssh_private_key>

Arguments:
  ssh_user          SSH user (must have password‑less sudo)
  vm_ip             IP address or hostname of the target VM
  ssh_private_key   Path to the SSH private key (read‑only)

The script expands the LVM LV mounted on /data with any newly added
blank disks.
EOF
    exit 1
}

# ---------- Argument parsing ----------
[[ $# -eq 3 ]] || usage
SSH_USER="$1"
VM_IP="$2"
SSH_KEY="$3"

[[ -r "$SSH_KEY" ]] || die "Cannot read SSH key: $SSH_KEY"

# ---------- Remote script (executed on the VM via sudo) ----------
REMOTE_BASH=$(cat <<'EOS'
set -euo pipefail

MOUNT_POINT="/data"

# -------------------------------------------------------------
# 1. Find the block device that backs /data
# -------------------------------------------------------------
LV_DEV=$(findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null) || {
    echo "No mount point $MOUNT_POINT – nothing to expand."
    exit 0
}
echo "Device backing $MOUNT_POINT: $LV_DEV"

# -------------------------------------------------------------
# 2. Locate the VG/LV that correspond to that device
# -------------------------------------------------------------
# lvs prints: vg_name : lv_name : lv_path
# Example line (no leading spaces):
#   data_vg:data_lv:/dev/data_vg/data_lv
LV_MATCH=$(lvs --noheadings --separator ':' -o vg_name,lv_name,lv_path 2>/dev/null |
    while IFS=':' read -r vg lv lp; do
        # Trim whitespace (defensive)
        vg=$(echo "$vg" | xargs)
        lv=$(echo "$lv" | xargs)
        lp=$(echo "$lp" | xargs)

        # Build the mapper name that the kernel creates
        mapper="/dev/mapper/${vg}-${lv}"

        # Compare the device returned by findmnt with either representation
        if [[ "$LV_DEV" == "$lp" || "$LV_DEV" == "$mapper" ]]; then
            echo "$vg:$lv:$lp"
            break
        fi
    done) || {
    echo "Could not locate an LVM LV for $LV_DEV"
    exit 1
}

# Parse the matched line
IFS=':' read -r VG_NAME LV_NAME LV_PATH <<< "$LV_MATCH"

if [[ -z "$VG_NAME" || -z "$LV_NAME" || -z "$LV_PATH" ]]; then
    echo "Failed to parse VG/LV information."
    exit 1
fi

echo "Found LV   : $LV_NAME"
echo "   VG     : $VG_NAME"
echo "   LV dev : $LV_PATH"

# -------------------------------------------------------------
# 3. List candidate disks (exclude the primary virtio disk /dev/vda)
# -------------------------------------------------------------
candidate_disks=()
while IFS= read -r name; do
    [[ "$name" == vda* ]] && continue    # primary boot disk
    [[ "$name" == loop* ]] && continue   # ignore loop devices
    candidate_disks+=( "/dev/$name" )
done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')

[[ ${#candidate_disks[@]} -gt 0 ]] || {
    echo "No extra physical disks discovered – nothing to do."
    exit 0
}
echo "Candidate extra disks: ${candidate_disks[*]}"

# -------------------------------------------------------------
# 4. Identify “blank” disks – no partition table and not already a PV
# -------------------------------------------------------------
blank_disks=()
for d in "${candidate_disks[@]}"; do
    if ! blkid "$d" >/dev/null 2>&1 && ! pvs "$d" >/dev/null 2>&1; then
        blank_disks+=( "$d" )
    fi
done

[[ ${#blank_disks[@]} -gt 0 ]] || {
    echo "No blank disks available for expansion."
    exit 0
}
echo "Blank disks that will become PVs: ${blank_disks[*]}"

# -------------------------------------------------------------
# 5. Initialise each blank disk as a PV and extend the VG
# -------------------------------------------------------------
for d in "${blank_disks[@]}"; do
    echo "Creating PV on $d ..."
    pvcreate -ff -y "$d"

    echo "Extending VG $VG_NAME with $d ..."
    vgextend "$VG_NAME" "$d"
done

# -------------------------------------------------------------
# 6. Grow the LV to consume all free space in the VG
# -------------------------------------------------------------
LV_FULL_PATH="/dev/${VG_NAME}/${LV_NAME}"
echo "Extending LV $LV_FULL_PATH to use all free space in VG $VG_NAME ..."
lvextend -l +100%FREE "$LV_FULL_PATH"

# -------------------------------------------------------------
# 7. Resize the filesystem (ext4 assumed)
# -------------------------------------------------------------
FS_TYPE=$(blkid -s TYPE -o value "$LV_PATH")
if [[ "$FS_TYPE" == "ext4" ]]; then
    echo "Resizing ext4 filesystem on $LV_PATH ..."
    resize2fs "$LV_PATH"
else
    echo "Filesystem type $FS_TYPE not supported – aborting."
    exit 1
fi

echo "Resize complete – $MOUNT_POINT now reflects the expanded capacity."
EOS
)

# ---------- Execute remote script via SSH ----------
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash -s" <<EOF
$REMOTE_BASH
EOF

echo "=== expand_data_volume.sh finished ==="
