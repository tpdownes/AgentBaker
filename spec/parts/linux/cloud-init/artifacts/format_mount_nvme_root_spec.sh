#!/bin/bash
# shellcheck disable=SC2329 # ShellSpec invokes hooks and command mocks.

Describe 'format-mount-nvme-root.sh'
    exec 19>/dev/null
    export BASH_XTRACEFD=19
    Include './parts/linux/cloud-init/artifacts/ubuntu/gb/format-mount-nvme-root.sh'
    set +x
    unset BASH_XTRACEFD
    exec 19>&-

    setup() {
        TEST_ROOT="$(mktemp -d)"
        RAID_DEVICE="${TEST_ROOT}/md/aks-local-nvme"
        LEGACY_RAID_DEVICE="${TEST_ROOT}/md0"
        DISK_DIR="${TEST_ROOT}/disks"
        MOUNT_POINT="${TEST_ROOT}/mnt/aks"
        KUBELET_DIR="${TEST_ROOT}/var/lib/kubelet"
        MDADM_CONFIG="${TEST_ROOT}/mdadm.conf"
        ASSEMBLE_SUCCESS=false
        ASSEMBLE_DEVICE="${RAID_DEVICE}"
        FILESYSTEM=ext4
        MEMBER_SIGNATURES=''
        ARRAY_SIGNATURES=''
        FAIL_PROBE=false
        FAIL_CREATE=false
        FAIL_FORMAT=false
        FAIL_MOUNT=false
        WRONG_MOUNT=false
        mkdir -p "${DISK_DIR}" "${KUBELET_DIR}" "${TEST_ROOT}/md"
        touch "${DISK_DIR}/1" "${DISK_DIR}/2" "${DISK_DIR}/3" "${DISK_DIR}/4"
        printf 'DEVICE partitions\nARRAY %s UUID=old\nARRAY %s UUID=legacy\nARRAY /dev/md1 UUID=unrelated\n' \
            "${RAID_DEVICE}" "${LEGACY_RAID_DEVICE}" > "${MDADM_CONFIG}"
    }

    cleanup() {
        rm -rf "${TEST_ROOT}"
    }

    # Regular files stand in for block devices; no real disks are accessed.
    test() {
        if [ "$#" -eq 2 ] && [ "$1" = -b ]; then
            [ -f "$2" ]
        else
            builtin test "$@"
        fi
    }

    mdadm() {
        case "$1" in
            --assemble)
                echo "mdadm $*"
                "${ASSEMBLE_SUCCESS}" || return 1
                touch "${ASSEMBLE_DEVICE}"
                ;;
            --create)
                echo "mdadm $*"
                "${FAIL_CREATE}" && return 1
                touch "${RAID_DEVICE}"
                ;;
            --detail)
                echo "ARRAY ${RAID_DEVICE} UUID=current"
                ;;
            *) return 1 ;;
        esac
    }

    wipefs() {
        "${FAIL_PROBE}" && return 1
        if [ "${!#}" = "${RAID_DEVICE}" ]; then
            printf '%s' "${ARRAY_SIGNATURES}"
        else
            printf '%s' "${MEMBER_SIGNATURES}"
        fi
    }

    blkid() {
        if [ -f "${TEST_ROOT}/formatted" ]; then
            echo ext4
        elif [ -n "${FILESYSTEM}" ]; then
            echo "${FILESYSTEM}"
        else
            return 2
        fi
    }

    mkfs.ext4() {
        echo "mkfs.ext4 $*"
        "${FAIL_FORMAT}" && return 1
        touch "${TEST_ROOT}/formatted"
    }

    mountpoint() {
        case "$2" in
            "${MOUNT_POINT}") [ -f "${TEST_ROOT}/volume-mounted" ] ;;
            *) return 1 ;;
        esac
    }

    findmnt() {
        ! "${WRONG_MOUNT}"
    }

    mount() {
        echo "mount $*"
        echo "$*" >> "${TEST_ROOT}/mounts"
        "${FAIL_MOUNT}" && return 1
        touch "${TEST_ROOT}/volume-mounted"
    }

    prepareDisk() {
        set -e
        prepareNvmeDisk "${RAID_DEVICE}" "${DISK_DIR}" "${MOUNT_POINT}" "${MDADM_CONFIG}" "${LEGACY_RAID_DEVICE}"
    }

    prepareTwice() {
        prepareDisk
        prepareDisk
    }

    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'creates and mounts a blank four-disk array without modifying kubelet state'
        FILESYSTEM=''
        touch "${KUBELET_DIR}/bootstrap-kubeconfig"

        When run prepareDisk

        The status should be success
        The output should include "mdadm --assemble --scan"
        The output should include "mdadm --create --verbose ${RAID_DEVICE} --name=aks-local-nvme --homehost=any --level=0 --raid-devices=4 ${DISK_DIR}/1 ${DISK_DIR}/2 ${DISK_DIR}/3 ${DISK_DIR}/4"
        The output should include "mkfs.ext4 -F -m 0 ${RAID_DEVICE}"
        The output should include "mount ${RAID_DEVICE} ${MOUNT_POINT}"
        The output should not include 'mount --bind'
        The path "${KUBELET_DIR}/bootstrap-kubeconfig" should be file
        The path "${MOUNT_POINT}/kubelet" should not be exist
        The contents of file "${MDADM_CONFIG}" should include 'UUID=current'
        The contents of file "${MDADM_CONFIG}" should include 'ARRAY /dev/md1 UUID=unrelated'
        The contents of file "${MDADM_CONFIG}" should include 'DEVICE partitions'
        The contents of file "${MDADM_CONFIG}" should not include 'UUID=old'
        The contents of file "${MDADM_CONFIG}" should not include 'UUID=legacy'
    End

    It 'assembles and preserves existing storage even before device symlinks are ready'
        ASSEMBLE_SUCCESS=true
        rm -rf "${DISK_DIR}"
        mkdir -p "${MOUNT_POINT}/kubelet"
        touch "${MOUNT_POINT}/kubelet/retained-state"

        When run prepareDisk

        The status should be success
        The output should include 'mdadm --assemble --scan'
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The path "${MOUNT_POINT}/kubelet/retained-state" should be file
    End

    It 'preserves an already active array without attempting assembly'
        touch "${RAID_DEVICE}"

        When run prepareDisk

        The status should be success
        The output should not include 'mdadm'
        The output should not include 'mkfs.ext4'
    End

    It 'preserves an existing legacy array when the named device is absent'
        touch "${LEGACY_RAID_DEVICE}"
        mkdir -p "${MOUNT_POINT}/kubelet"
        touch "${MOUNT_POINT}/kubelet/retained-state"

        When run prepareDisk

        The status should be success
        The output should include "mount ${LEGACY_RAID_DEVICE} ${MOUNT_POINT}"
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The path "${MOUNT_POINT}/kubelet/retained-state" should be file
    End

    It 'preserves a legacy array assembled on reboot before device symlinks are ready'
        ASSEMBLE_SUCCESS=true
        ASSEMBLE_DEVICE="${LEGACY_RAID_DEVICE}"
        rm -rf "${DISK_DIR}"
        mkdir -p "${MOUNT_POINT}/kubelet"
        touch "${MOUNT_POINT}/kubelet/retained-state"

        When run prepareDisk

        The status should be success
        The output should include 'mdadm --assemble --scan'
        The output should include "mount ${LEGACY_RAID_DEVICE} ${MOUNT_POINT}"
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The path "${MOUNT_POINT}/kubelet/retained-state" should be file
    End

    It 'prefers the named array when a legacy device also exists'
        touch "${RAID_DEVICE}" "${LEGACY_RAID_DEVICE}"

        When run prepareDisk

        The status should be success
        The output should include "mount ${RAID_DEVICE} ${MOUNT_POINT}"
        The output should not include "mount ${LEGACY_RAID_DEVICE} ${MOUNT_POINT}"
        The output should not include 'mdadm'
        The output should not include 'mkfs.ext4'
    End

    It 'recreates storage after local disks are replaced with blank disks'
        FILESYSTEM=''

        When run prepareDisk

        The status should be success
        The output should include 'mdadm --create'
        The output should include 'mkfs.ext4'
        The path "${MOUNT_POINT}" should be directory
        The path "${KUBELET_DIR}" should be directory
    End

    It 'refuses to recreate an unassembled array with retained RAID metadata'
        MEMBER_SIGNATURES=linux_raid_member

        When run prepareDisk

        The status should be failure
        The error should include 'Refusing to recreate RAID over existing signatures'
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The output should not include 'mount '
    End

    It 'does not create an array when any expected disk is missing'
        rm "${DISK_DIR}/4"

        When run prepareDisk

        The status should be failure
        The error should include "Local NVMe disk is not available: ${DISK_DIR}/4"
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
    End

    It 'stops if disk signatures cannot be inspected'
        FAIL_PROBE=true

        When run prepareDisk

        The status should be failure
        The output should not include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The output should not include 'mount '
    End

    It 'does not format or mount if array creation fails'
        FAIL_CREATE=true
        touch "${KUBELET_DIR}/fresh-state"

        When run prepareDisk

        The status should be failure
        The output should include 'mdadm --create'
        The output should not include 'mkfs.ext4'
        The output should not include 'mount '
        The path "${KUBELET_DIR}/fresh-state" should be file
    End

    It 'finishes formatting an array left blank by an interrupted first boot'
        touch "${RAID_DEVICE}"
        FILESYSTEM=''

        When run prepareDisk

        The status should be success
        The output should not include 'mdadm --create'
        The output should include "mkfs.ext4 -F -m 0 ${RAID_DEVICE}"
    End

    It 'preserves an unexpected filesystem instead of reformatting it'
        touch "${RAID_DEVICE}"
        FILESYSTEM=xfs

        When run prepareDisk

        The status should be failure
        The error should include 'found xfs'
        The output should not include 'mkfs.ext4'
        The output should not include 'mount '
    End

    It 'does not format ambiguous array signatures when filesystem probing fails'
        touch "${RAID_DEVICE}"
        FILESYSTEM=''
        ARRAY_SIGNATURES=gpt

        When run prepareDisk

        The status should be failure
        The error should include 'Refusing to format existing signatures'
        The output should not include 'mkfs.ext4'
    End

    It 'does not mount if formatting fails'
        touch "${RAID_DEVICE}"
        FILESYSTEM=''
        FAIL_FORMAT=true
        touch "${KUBELET_DIR}/fresh-state"

        When run prepareDisk

        The status should be failure
        The output should include 'mkfs.ext4'
        The output should not include 'mount '
        The path "${KUBELET_DIR}/fresh-state" should be file
    End

    It 'does not stack volume mounts on a service retry'
        touch "${RAID_DEVICE}"

        When run prepareTwice

        The status should be success
        The output should include "mount ${RAID_DEVICE} ${MOUNT_POINT}"
        The contents of file "${TEST_ROOT}/mounts" should equal "${RAID_DEVICE} ${MOUNT_POINT}"
    End

    It 'reports failure when mounting the volume fails'
        touch "${RAID_DEVICE}" "${KUBELET_DIR}/fresh-state"
        FAIL_MOUNT=true

        When run prepareDisk

        The status should be failure
        The output should not include 'mount --bind'
        The path "${KUBELET_DIR}/fresh-state" should be file
    End

    It 'rejects a volume mount from a different device'
        touch "${RAID_DEVICE}" "${TEST_ROOT}/volume-mounted"
        WRONG_MOUNT=true

        When run prepareDisk

        The status should be failure
        The error should include 'is mounted from a different device'
        The output should not include 'mount --bind'
    End

End
