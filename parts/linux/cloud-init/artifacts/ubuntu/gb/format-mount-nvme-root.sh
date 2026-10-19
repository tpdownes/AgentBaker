#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -x

prepareNvmeArray() {
    local raid_device="$1"
    local disk_dir="$2"
    local mdadm_config="$3"
    local raid_name="$4"
    local legacy_raid_device="$5"

    if ! test -b "${raid_device}"; then
        local disks=("${disk_dir}/1" "${disk_dir}/2" "${disk_dir}/3" "${disk_dir}/4")
        local disk signatures
        for disk in "${disks[@]}"; do
            if ! test -b "${disk}"; then
                echo "Local NVMe disk is not available: ${disk}" >&2
                return 1
            fi
            signatures=$(wipefs --no-act --noheadings --output TYPE "${disk}")
            if [ -n "${signatures}" ]; then
                echo "Refusing to recreate RAID over existing signatures on ${disk}" >&2
                return 1
            fi
        done

        mdadm --create --verbose "${raid_device}" --name="${raid_name}" --homehost=any --level=0 --raid-devices=4 "${disks[@]}"

        # Replace this array's old UUID after local-disk replacement, preserving
        # unrelated mdadm configuration. Save before formatting so a retry can
        # assemble an array whose filesystem creation was interrupted.
        local array_config config_tmp
        array_config=$(mdadm --detail --brief "${raid_device}")
        config_tmp=$(mktemp)
        if [ -f "${mdadm_config}" ]; then
            awk -v device="${raid_device}" -v legacy="${legacy_raid_device}" \
                '$1 != "ARRAY" || ($2 != device && $2 != legacy)' "${mdadm_config}" > "${config_tmp}"
        fi
        printf '%s\n' "${array_config}" >> "${config_tmp}"
        cat "${config_tmp}" > "${mdadm_config}"
        rm -f "${config_tmp}"
    fi

    local filesystem
    if filesystem=$(blkid -p -s TYPE -o value "${raid_device}"); then
        if [ "${filesystem}" != ext4 ]; then
            echo "Expected ext4 on ${raid_device}, found ${filesystem}" >&2
            return 1
        fi
    else
        # An existing array without a filesystem can be left by an interrupted
        # first boot. Probe all signatures before formatting it.
        local signatures
        signatures=$(wipefs --no-act --noheadings --output TYPE "${raid_device}")
        if [ -n "${signatures}" ]; then
            echo "Refusing to format existing signatures on ${raid_device}" >&2
            return 1
        fi
        # Kubelet storage does not need blocks reserved for the root user.
        mkfs.ext4 -F -m 0 "${raid_device}"
    fi
}

prepareNvmeDisk() {
    local raid_name="aks-local-nvme"
    local raid_device="${1:-/dev/md/${raid_name}}"
    local disk_dir="${2:-/dev/disk/azure/local/by-index}"
    local mount_point="${3:-/mnt/aks}"
    local mdadm_config="${4:-/etc/mdadm/mdadm.conf}"
    local legacy_raid_device="${5:-/dev/md0}"

    if ! test -b "${raid_device}"; then
        # Assemble from superblocks before considering creation. On reboot,
        # waagent's by-index symlinks may not be available yet.
        mdadm --assemble --scan || true
    fi
    # Preserve arrays created by older GB images without changing their
    # superblocks or filesystem. New arrays use the stable name above.
    if ! test -b "${raid_device}" && test -b "${legacy_raid_device}"; then
        raid_device="${legacy_raid_device}"
    fi

    prepareNvmeArray "${raid_device}" "${disk_dir}" "${mdadm_config}" "${raid_name}" "${legacy_raid_device}"

    mkdir -p "${mount_point}"
    if mountpoint -q "${mount_point}"; then
        if ! findmnt --noheadings --mountpoint "${mount_point}" --source "${raid_device}" > /dev/null; then
            echo "${mount_point} is mounted from a different device" >&2
            return 1
        fi
    else
        mount "${raid_device}" "${mount_point}"
    fi
}

# Prevent ShellSpec from executing the production entry point when sourcing.
${__SOURCED__:+return}

prepareNvmeDisk
