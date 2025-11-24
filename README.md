# lvmstitch
A repo with examples of scripts that stitch volumes together with LVM on Civo's public cloud platform compute instances.

The original issue: A user would like to provide ephemeral Linux VMs to customers. When a VM is created, they would like to create a 50GB file system attached to the VM which expands dynamically up to 1TB. On shutting down the VM, the volume is kept for 72 hours. If a user creates a new VM in that time, they may choose to reattach that volume. If they do, the timer resets.

While this capability is not inherent inside the Civo system, it is possible to automate something approximating it. Ideally, this would be done using the user's existing automation tooling, for example making API calls to Civo's API and interacting with the OS with something like Ansible; however, for the purposes of this demonstration we'll be doing it with a series of bash scripts and the Civo CLI.

Because it is up to the user what their automation tooling is like, we have left the triggering of the execution open to interpretation. Whatever triggers the creation and deletion of resources would execute the automation accordingly. The deletion and handling of the "resetting the clock" would also need to be handled by the automation; however, this is likely trivial to implement with any event/automation system capable of handling monitoring/timed execution.

One last note is that if the user requires new VMs to have software installed on instantiation, this can be done with an initialisation script:

`civo instance create --script <path to a script that will be uploaded to /usr/local/bin/civo-user-init-script on your instance, read/write/executable only by root and then will be executed at the end of the cloud initialization>`

## The scripts:

### provision_data_mount.sh

Connects to a remote VM (user, IP, SSH‑key) and:
- Finds all physical disks that are NOT /dev/vda
- Detects any existing LVM LV on those disks
- If exactly one LV exists → mount it on /data (persistent)
- If no LV exists but a “blank” disk is present → create a PV, VG, LV, format it, and mount it on /data (persistent)
The script aborts if >1 LV is found or if anything goes wrong.

### expand_data_volume.sh

- Detect any newly‑attached “blank” disks on a remote VM.
- Add them as LVM physical volumes to the VG that already contains the LV mounted on /data.
- Grow the LV to consume all free space in the VG.
- Resize the ext4 filesystem so the extra space appears under /data.

## Process/Usage:

0. Prereqs:
- Civo account with sufficient quota
- Civo API key set up in Civo CLI
- SSH key set up with Civo account, and a local copy of the private key file (e.g. ~/.ssh/id_rsa)
- Somewhere that the Civo CLI and bash scripts can run from (Linux, Mac, or Windows with WSL)

1. Create initial VM

`civo instance create test-vm --size g4s.small --diskimage ubuntu-noble --sshkey my-ssh-key --wait`

2. Create 50GB volume:

`civo volume create data01 --size-gb 50`

3. Attach the volume to the VM:

`civo volume attach data01 test-vm`

4. Reboot the VM:

`civo instance reboot test-vm`

5. Wait for the instance to come back up and get the IP address of test-vm:

`civo instance show test-vm`

6. Run the provision script:

`./provision_data_mount.sh civo <IP ADDRESS> ~/.ssh/id_rsa`

This will log in to the VM via SSH using the private key specified (public key uploaded to the Civo instance using --sshkey my-ssh-key on creation), search for the newly provisioned and attached blank volume, add it to LVM as a physical volume, create a volume group, and create a logical volume from that group. It then mounts the logical volume to /data.

7. Check/use the storage (on the VM):

```
$ df -h /data
Filesystem                   Size  Used Avail Use% Mounted on
/dev/mapper/data_vg-data_lv  49G   24K  49G   1% /data
```

8. Expand the storage - first create new volumes and attach them to the VM:

```
civo volume create data02 --size-gb 50
civo volume attach data02 test-vm
civo volume create data03 --size-gb 50
civo volume attach data03 test-vm
```

9. Initialise and add the new volumes on the VM:

`./expand_data_volume.sh civo <IP ADDRESS> ~/.ssh/id_rsa`

This will automatically find, initialise, and add the volumes to the existing LVM volume group and logical volume, and expand the filesystem to use the new space.

10. Check/use the storage (on the VM):

```
df -h /data
Filesystem                   Size  Used Avail Use% Mounted on
/dev/mapper/data_vg-data_lv  138G   24K  132G   1% /data
```

11. User deletes the VM:

`civo instance delete test-vm`

This automatically detatches the volumes.

12. Create a new, replacement VM:

`civo create instance new-test-vm --size g4s.small --diskimage ubuntu-noble --sshkey my-ssh-key --wait`

13. Reattach the existing volumes to the new VM:

```
civo volume attach data01 new-test-vm
civo volume attach data02 new-test-vm
civo volume attach data03 new-test-vm
```

14. Find and recreate the logical volume on /data:

`./provision_data_mount.sh civo <IP ADDRESS> ~/.ssh/id_rsa`

15. Check/use the storage (on the VM):

```
df -h /data
Filesystem                   Size  Used Avail Use% Mounted on
/dev/mapper/data_vg-data_lv  138G   24K  132G   1% /data
```
