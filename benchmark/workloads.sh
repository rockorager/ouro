#!/usr/bin/env bash

# name                 client mode  clients width height frames warmup
benchmark_workloads=(
    "shm-full          shm-full     1       1280  720    1000   3"
    "shm-tiny          shm-tiny     1       1280  720    1000   3"
    "shm-sparse        shm-sparse   1       1280  720    1000   3"
    "shm-dual-sparse   shm-sparse   2       640   720    1000   3"
)
