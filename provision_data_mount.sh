#!/usr/bin/env bash
# ------------------------------------------------------------
# provision_data_mount.sh
#   Connects to a remote VM (user, IP, SSH‑key) and:
#     • Finds all physical disks that are NOT /dev/vda
#     • Detects any existing LVM LV on those disks
#     • If exactly one LV exists → mount it on /data (persistent)
#     • If no LV exists but a “blank” disk is present → create a
#       PV, VG, LV, format it, and mount it on /data (persistent)
#   The script aborts if >1 LV is found or if anything goes wrong.
#
# Requirements on the target VM:
#     • sudo access without a password prompt
#     • lvm2, util‑linux (lsblk, blkid), e2fsprogs (mkfs.ext4)
# ------------------------------------------------------------

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
  ssh_user          User name for the SSH connection (must have sudo rights)
  vm_ip             IP address or hostname of the target VM
  ssh_private_key   Path to the SSH private key file (read‑only)

The script will connect to the VM and ensure a single LVM logical volume
is mounted on /data, creating it if necessary.
EOF
    exit 1
}

# ---------- Parse arguments ----------
[[ $# -eq 3 ]] || usage
SSH_USER="$1"
VM_IP="$2"
SSH_KEY="$3"

[[ -r "$SSH_KEY" ]] || die "Cannot read SSH key: $SSH_KEY"

# ---------- Remote script (executed via sudo) ----------
REMOTE_BASH=$(cat <<'EOS'
set -euo pipefail

# ---- 1. Find candidate disks (exclude /dev/vda) ----
candidate_disks=()
while IFS= read -r dev; do
    # Skip vda (the default virtio disk) and loop devices
    [[ "$dev" == vda* ]] && continue
    candidate_disks+=( "/dev/$dev" )
done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')

[[ ${#candidate_disks[@]} -gt 0 ]] || {
    echo "No non‑vda physical disks found – nothing to do."
    exit 0
}

echo "Candidate disks: ${candidate_disks[*]}"

# ---- 2. Look for existing LVM objects on those disks ----
# Use an associative array to keep each LV only once, even if the
# same VG is seen on several physical disks.
declare -A seen_lvs   # key = /dev/<vg>/<lv> , value is irrelevant

for d in "${candidate_disks[@]}"; do
    # Does the disk belong to an LVM PV?
    if pvs --noheadings -o pv_name 2>/dev/null | grep -qw "$d"; then
        # Get the VG that owns the PV
        vg=$(pvs --noheadings -o vg_name "$d" | tr -d ' ')
        # List LVs in that VG – we do this only once per VG because
        # the associative array will silently ignore duplicates.
        while IFS= read -r lv; do
            # Build the full device path, e.g. /dev/data_vg/data_lv
            dev_path="/dev/${vg}/${lv}"
            seen_lvs["$dev_path"]=1
        done < <(lvs --noheadings -o lv_name "$vg" | tr -d ' ')
    fi
done

# Convert the associative‑array keys into a normal indexed array for the
# rest of the script (the rest of the file expects `${existing_lvs[@]}`).
existing_lvs=()
for dev in "${!seen_lvs[@]}"; do
    existing_lvs+=( "$dev" )
done

# ---- 3. React according to what we found ----
if [[ ${#existing_lvs[@]} -gt 1 ]]; then
    echo "More than one LVM LV found (${existing_lvs[*]}). Exiting."
    exit 1
fi

mount_point="/data"

# Helper: ensure /data exists and fstab entry
ensure_mount() {
    local dev_path="$1"
    local uuid
    uuid=$(blkid -s UUID -o value "$dev_path")
    [[ -n "$uuid" ]] || { echo "Unable to get UUID for $dev_path"; exit 1; }

    # Create mount point if missing
    mkdir -p "$mount_point"

    # Idempotent fstab entry
    if ! grep -qE "[[:space:]]$mount_point[[:space:]]" /etc/fstab; then
        echo "UUID=$uuid  $mount_point  ext4  defaults  0 2" >> /etc/fstab
        echo "Added fstab entry for $dev_path -> $mount_point"
    else
        echo "fstab already contains an entry for $mount_point"
    fi

    # Mount now (won't fail if already mounted)
    mount "$mount_point" || true
    echo "Mounted $dev_path on $mount_point"
}

if [[ ${#existing_lvs[@]} -eq 1 ]]; then
    # ---- 3a. Exactly one LV already exists ----
    echo "Found existing LV: ${existing_lvs[0]}"
    ensure_mount "${existing_lvs[0]}"
    exit 0
fi

# ---- 4. No existing LV – look for a blank disk ----
blank_disk=""
for d in "${candidate_disks[@]}"; do
    # A “blank” disk has:
    #   • No partition table (blkid returns nothing)
    #   • Not already a PV
    if ! blkid "$d" >/dev/null 2>&1 && ! pvs "$d" >/dev/null 2>&1; then
        blank_disk="$d"
        break
    fi
done

[[ -n "$blank_disk" ]] || {
    echo "No blank disks available to initialise. Exiting."
    exit 1
}

echo "Initialising blank disk $blank_disk as LVM PV"

# ---- 5. Initialise LVM on the blank disk ----
vg_name="data_vg"
lv_name="data_lv"

# Create PV
pvcreate -ff -y "$blank_disk"

# Create or extend VG
if vgdisplay "$vg_name" &>/dev/null; then
    vgextend "$vg_name" "$blank_disk"
else
    vgcreate "$vg_name" "$blank_disk"
fi

# Create LV using all free space
lvcreate -l 100%FREE -n "$lv_name" "$vg_name"

dev_path="/dev/${vg_name}/${lv_name}"

# ---- 6. Format, mount and persist ----
mkfs.ext4 -F "$dev_path"
ensure_mount "$dev_path"
EOS
)

# ---------- 7. Run remote script via SSH ----------
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash -s" <<EOF
$REMOTE_BASH
EOF

echo "Provisioning complete."

