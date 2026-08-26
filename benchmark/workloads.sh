#!/usr/bin/env bash

# name                 client mode  clients width height frames warmup
benchmark_workloads=(
    "shm-full          shm-full     1       1280  720    1000   3"
    "shm-tiny          shm-tiny     1       1280  720    1000   3"
    "shm-sparse        shm-sparse   1       1280  720    1000   3"
    "shm-dual-sparse   shm-sparse   2       640   720    1000   3"
    "shm-static        shm-static    1       1280  720    1000   3"
    "shm-scale-1       shm-sparse   1       640   360    1000   3"
    "shm-scale-2       shm-sparse   2       640   360    1000   3"
    "shm-scale-8       shm-sparse   8       640   360    1000   3"
    "shm-buffer-churn  shm-churn    1       1280  720    600    3"
    "dmabuf-sparse     dmabuf-sparse 1      1280  720    1000   3"
    "dmabuf-scale-1    dmabuf-sparse 1      640   360    1000   3"
    "dmabuf-scale-2    dmabuf-sparse 2      640   360    1000   3"
    "dmabuf-scale-8    dmabuf-sparse 8      640   360    1000   3"
    "dmabuf-churn      dmabuf-churn 1       1280  720    300    3"
)
