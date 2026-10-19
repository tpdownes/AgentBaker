#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Bind mount kubelet to prepared ephemeral storage on startup.
#
# This fixes an issue with kubelet's ability to detect allocatable
# capacity for Node ephemeral-storage. /mnt/aks is backed by the temporary
# disk, or by local NVMe RAID prepared by the GB storage service. Binding
# its kubelet directory at /var/lib/kubelet exposes that storage's capacity.

prepareKubeletDisk() {
    local mount_point="${1:-/mnt/aks}"
    local kubelet_dir="${2:-/var/lib/kubelet}"
    local kubelet_mount_point="${mount_point}/kubelet"

    mkdir -p "${mount_point}"
    if mountpoint -q "${kubelet_dir}"; then
        if [ ! "${kubelet_dir}" -ef "${kubelet_mount_point}" ]; then
            echo "${kubelet_dir} is already mounted from a different directory" >&2
            return 1
        fi
    else
        mkdir -p "${kubelet_dir}"
        # A populated OS-disk directory contains fresh provisioning state,
        # including after an OS reimage. An empty one is left by migration and
        # must not replace retained kubelet state on an ordinary reboot.
        local source_entry
        source_entry=$(find "${kubelet_dir}" -mindepth 1 -maxdepth 1 -print -quit)
        if [ -n "${source_entry}" ]; then
            rm -rf --one-file-system "${kubelet_mount_point}"
            mv "${kubelet_dir}" "${kubelet_mount_point}"
        elif [ ! -d "${kubelet_mount_point}" ]; then
            mv "${kubelet_dir}" "${kubelet_mount_point}"
        fi

        mkdir -p "${kubelet_dir}"
        mount --bind "${kubelet_mount_point}" "${kubelet_dir}"
    fi

    # The directory holds the kubelet kubeconfig and TLS material, so it must
    # never be writable by unprivileged local users. Preserve its existing
    # read and execute permissions while removing group and other write access.
    chown root:root "${kubelet_dir}"
    chmod go-w "${kubelet_dir}"
}

# Prevent ShellSpec from executing the production entry point when sourcing.
${__SOURCED__:+return}

prepareKubeletDisk
