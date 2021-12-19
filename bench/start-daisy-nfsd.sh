#!/usr/bin/env bash

set -eu

#
# Usage:  ./start-daisy-nfsd.sh <arguments>
#
# default disk is /dev/shm/nfs.img but can be overriden by passing -disk again
#

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# root of repo
cd "$DIR"/..

disk_path=/dev/shm/nfs.img
nfs_mount_opts=""
nfs_mount_path="/mnt/nfs"
jrnl_patch_path=""
extra_args=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -disk)
            shift
            disk_path="$1"
            shift
            ;;
        -nfs-mount-opts)
            shift
            nfs_mount_opts="$1"
            shift
            ;;
        -mount-path)
            shift
            nfs_mount_path="$1"
            shift
            ;;
        -jrnlpatch)
            shift
            jrnl_patch_path="$1"
            shift
            ;;
        -*=*)
            extra_args+=("$1")
            shift
            ;;
        -*)
            extra_args+=("$1" "$2")
            shift
            shift
            ;;
    esac
done

# make sure code is compiled in case it takes longer than 2s to build
make --quiet compile
if [[ ! -z "$jrnl_patch_path" ]]
then
	jrnl_patch_path=$(realpath "$jrnl_patch_path")

	pushd "$GO_JRNL_PATH"
	git apply "$jrnl_patch_path"
	popd

	pushd "$DAISY_NFSD_PATH"
	go mod edit -replace github.com/mit-pdos/go-journal="$GO_JRNL_PATH"
	popd
fi
go build ./cmd/daisy-nfsd
if [[ ! -z "$jrnl_patch_path" ]]
then
	pushd "$GO_JRNL_PATH"
	git reset --hard
	popd

	pushd "$DAISY_NFSD_PATH"
	go mod edit -dropreplace github.com/mit-pdos/go-journal
	popd
fi

killall -w daisy-nfsd 2>/dev/null || true
umount -f "$nfs_mount_path" 2>/dev/null || true
./daisy-nfsd -debug=0 -disk "$disk_path" "${extra_args[@]}" 1>nfs.out 2>&1 &
sleep 2
killall -0 daisy-nfsd       # make sure server is running
killall -SIGUSR1 daisy-nfsd # reset stats after recovery

# mount options for Linux NFS client:
#
# vers=3 is the default but nice to be explicit
#
# nordirplus tells the client not to try READDIRPLUS (it will fall back to
# READDIR but always first try READDIRPLUS)
#
# nolock tells the client not to try to use the Network Lock Manager for
# advisory locks since our server doesn't run one; instead, clients use local
# locks which work fine if there's only one client
_nfs_mount="vers=3,nordirplus,nolock"
if [ -n "$nfs_mount_opts" ]; then
    _nfs_mount="vers=3,nordirplus,$nfs_mount_opts"
fi

sudo mount -t nfs -o "${_nfs_mount}" localhost:/ "$nfs_mount_path"
