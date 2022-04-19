#!/usr/bin/env bash

set -eu

cd ~/daisy-nfsd

go build ./cmd/daisy-eval
mkdir -p eval/data/nvme
sudo chown "$USER" /dev/nvme1n1

./daisy-eval --filesystems daisy-nfsd,linux --dir eval/data/nvme --disk /dev/nvme1n1 --iters 1 bench
rm eval/data/nvme/*

time ./daisy-eval --filesystems daisy-nfsd,linux --dir eval/data/nvme --disk /dev/nvme1n1 --iters 10 bench
time ./daisy-eval --filesystems daisy-nfsd,linux --dir eval/data/nvme --disk /dev/nvme1n1 --iters 3 scale --benchtime=10s --threads 36
time ./daisy-eval --filesystems daisy-nfsd,linux --dir eval/data --disk "/dev/shm/disk.img" --iters 10 bench

#time ./daisy-eval --filesystems daisy-nfsd,linux --dir eval/data--disk "/dev/shm/disk.img" --iters 3 scale --benchtime=10s --threads 36

# some other things to try
#time ./daisy-eval --filesystems durability --dir eval/data/nvme --disk /dev/nvme1n1 --iters 10 --wait 3s largefile
#time ./daisy-eval --filesystems durability --dir eval/data --disk "/dev/shm/disk.img" --iters 10 --wait 3s largefile
