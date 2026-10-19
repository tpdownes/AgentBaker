#!/bin/bash
# shellcheck disable=SC2329 # ShellSpec invokes hooks and command mocks.

Describe 'bind-mount.sh'
    exec 19>/dev/null
    export BASH_XTRACEFD=19
    Include './parts/linux/cloud-init/artifacts/bind-mount.sh'
    set +x
    unset BASH_XTRACEFD
    exec 19>&-

    setup() {
        TEST_ROOT="$(mktemp -d)"
        MOUNT_POINT="${TEST_ROOT}/mnt/aks"
        KUBELET_MOUNT_POINT="${MOUNT_POINT}/kubelet"
        KUBELET_DIR="${TEST_ROOT}/var/lib/kubelet"
        SENTINEL_FILE="${TEST_ROOT}/opt/azure/containers/bind-sentinel"
        FAIL_MOUNT=false
        FAIL_FIND=false
        FAIL_CHOWN=false
        mkdir -p "${KUBELET_DIR}" "$(dirname "${SENTINEL_FILE}")"
    }

    cleanup() {
        rm -rf "${TEST_ROOT}"
    }

    mountpoint() {
        [ "$2" = "${KUBELET_DIR}" ] && [ -f "${TEST_ROOT}/kubelet-mounted" ]
    }

    mount() {
        echo "mount $*"
        "${FAIL_MOUNT}" && return 1
        echo "$*" >> "${TEST_ROOT}/mounts"
        # A symlink models the shared inode of the two bind mount paths.
        rmdir "$3"
        ln -s "$2" "$3"
        touch "${TEST_ROOT}/kubelet-mounted"
    }

    find() {
        "${FAIL_FIND}" && return 1
        command find "$@"
    }

    chmod() {
        echo "chmod $*"
    }

    chown() {
        echo "chown $*"
        ! "${FAIL_CHOWN}"
    }

    prepareDisk() {
        set -e
        prepareKubeletDisk "${MOUNT_POINT}" "${KUBELET_DIR}"
    }

    prepareTwice() {
        prepareDisk
        prepareDisk
    }

    retryAfterFailure() {
        # Run the failed attempt with errexit in its own subshell, then retry
        # against the actual directories it left behind.
        set +e
        (set -e; prepareKubeletDisk "${MOUNT_POINT}" "${KUBELET_DIR}")
        local status=$?
        set -e
        [ "${status}" -ne 0 ]
        FAIL_MOUNT=false
        FAIL_CHOWN=false
        prepareDisk
    }

    BeforeEach 'setup'
    AfterEach 'cleanup'

    It 'moves fresh kubelet state onto prepared storage without a sentinel'
        touch "${KUBELET_DIR}/bootstrap-kubeconfig"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_MOUNT_POINT}/bootstrap-kubeconfig" should be file
        The path "${KUBELET_DIR}/bootstrap-kubeconfig" should be file
        The path "${SENTINEL_FILE}" should not be exist
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
        The output should include "chown root:root ${KUBELET_DIR}"
        The output should include "chmod go-w ${KUBELET_DIR}"
        The output should not include "chmod a+w"
    End

    It 'resets retained kubelet state after an OS disk reimage'
        mkdir -p "${KUBELET_MOUNT_POINT}" "${MOUNT_POINT}/containers"
        touch "${KUBELET_MOUNT_POINT}/stale-state"
        touch "${MOUNT_POINT}/containers/image-cache"
        touch "${KUBELET_DIR}/fresh-state"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_MOUNT_POINT}/stale-state" should not be exist
        The path "${KUBELET_MOUNT_POINT}/fresh-state" should be file
        The path "${KUBELET_MOUNT_POINT}/kubelet" should not be exist
        The path "${MOUNT_POINT}/containers/image-cache" should be file
        The path "${SENTINEL_FILE}" should not be exist
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'preserves retained kubelet state on reboot with an empty OS-disk directory'
        mkdir -p "${KUBELET_MOUNT_POINT}"
        touch "${KUBELET_MOUNT_POINT}/current-state"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_DIR}/current-state" should be file
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'preserves retained state when an old image left a sentinel'
        mkdir -p "${KUBELET_MOUNT_POINT}"
        touch "${KUBELET_MOUNT_POINT}/current-state" "${SENTINEL_FILE}"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_DIR}/current-state" should be file
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'preserves retained state if the OS-disk mountpoint needs to be recreated'
        rmdir "${KUBELET_DIR}"
        mkdir -p "${KUBELET_MOUNT_POINT}"
        touch "${KUBELET_MOUNT_POINT}/current-state"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_DIR}/current-state" should be file
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'initializes empty storage on first boot with an empty kubelet directory'
        When run prepareDisk

        The status should be success
        The path "${KUBELET_MOUNT_POINT}" should be directory
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'initializes blank replacement storage even when an old sentinel remains'
        touch "${SENTINEL_FILE}"

        When run prepareDisk

        The status should be success
        The path "${KUBELET_MOUNT_POINT}" should be directory
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'does not stack mounts or repeat migration on a service retry'
        touch "${KUBELET_DIR}/fresh-state"

        When run prepareTwice

        The status should be success
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
        The contents of file "${TEST_ROOT}/mounts" should equal "--bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
        The path "${KUBELET_DIR}/fresh-state" should be file
        The path "${KUBELET_MOUNT_POINT}/kubelet" should not be exist
    End

    It 'preserves migrated data on a retry after binding failed'
        touch "${KUBELET_DIR}/fresh-state"
        FAIL_MOUNT=true

        When run retryAfterFailure

        The status should be success
        The output should include "mount --bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
        The path "${KUBELET_DIR}/fresh-state" should be file
        The path "${KUBELET_MOUNT_POINT}/kubelet" should not be exist
        The contents of file "${TEST_ROOT}/mounts" should equal "--bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
    End

    It 'retries permissions without rebinding or deleting data'
        touch "${KUBELET_DIR}/fresh-state"
        FAIL_CHOWN=true

        When run retryAfterFailure

        The status should be success
        The path "${KUBELET_DIR}/fresh-state" should be file
        The contents of file "${TEST_ROOT}/mounts" should equal "--bind ${KUBELET_MOUNT_POINT} ${KUBELET_DIR}"
        The output should include "chmod go-w ${KUBELET_DIR}"
    End

    It 'rejects an existing kubelet mount from a different directory'
        mkdir -p "${KUBELET_MOUNT_POINT}"
        touch "${TEST_ROOT}/kubelet-mounted" "${KUBELET_DIR}/fresh-state"

        When run prepareDisk

        The status should be failure
        The error should include 'is already mounted from a different directory'
        The output should not include 'mount '
        The path "${KUBELET_DIR}/fresh-state" should be file
    End

    It 'stops before deleting retained data when the OS-disk directory cannot be inspected'
        mkdir -p "${KUBELET_MOUNT_POINT}"
        touch "${KUBELET_MOUNT_POINT}/current-state"
        FAIL_FIND=true

        When run prepareDisk

        The status should be failure
        The path "${KUBELET_MOUNT_POINT}/current-state" should be file
        The output should not include 'mount '
    End

    It 'reports a bind failure without changing permissions on the OS-disk mountpoint'
        touch "${KUBELET_DIR}/fresh-state"
        FAIL_MOUNT=true

        When run prepareDisk

        The status should be failure
        The path "${KUBELET_MOUNT_POINT}/fresh-state" should be file
        The output should not include 'chown '
        The output should not include 'chmod '
    End
End
