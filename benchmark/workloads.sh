#!/usr/bin/env bash

# A comma-separated mode list assigns one mode per client; one mode is repeated.
# name                    client modes                         clients width height frames warmup
benchmark_workloads=(
    "shm-full             shm-full                             1       1280  720    1000   3"
    "shm-tiny             shm-tiny                             1       1280  720    1000   3"
    "shm-sparse           shm-sparse                           1       1280  720    1000   3"
    "shm-moving           shm-moving                           1       1280  720    1000   3"
    "shm-multirect-8      shm-multirect-8                      1       1280  720    1000   3"
    "shm-multirect-9      shm-multirect-9                      1       1280  720    1000   3"
    "shm-dual-sparse      shm-sparse                           2       640   720    1000   3"
    "shm-static           shm-static                           1       1280  720    1000   3"
    "shm-scale-1          shm-sparse                           1       640   360    1000   3"
    "shm-scale-2          shm-sparse                           2       640   360    1000   3"
    "shm-scale-8          shm-sparse                           8       640   360    1000   3"
    "shm-scale-16         shm-sparse                           16      640   360    1000   3"
    "shm-scale-32         shm-sparse                           32      640   360    1000   3"
    "shm-scale-64         shm-sparse                           64      640   360    1000   3"
    "shm-buffer-churn     shm-churn                            1       1280  720    600    3"
    "shm-churn-2          shm-churn                            2       640   360    600    3"
    "shm-churn-8          shm-churn                            8       640   360    600    3"
    "dmabuf-full          dmabuf-full                          1       1280  720    1000   3"
    "dmabuf-tiny          dmabuf-tiny                          1       1280  720    1000   3"
    "dmabuf-sparse        dmabuf-sparse                        1       1280  720    1000   3"
    "dmabuf-moving        dmabuf-moving                        1       1280  720    1000   3"
    "dmabuf-multirect-8   dmabuf-multirect-8                   1       1280  720    1000   3"
    "dmabuf-multirect-9   dmabuf-multirect-9                   1       1280  720    1000   3"
    "viewport-control-shm shm-full                             1       1280  720    1000   3"
    "viewport-crop-shm    shm-viewport-crop                    1       1280  720    1000   3"
    "viewport-scale-shm   shm-viewport-scale                   1       1280  720    1000   3"
    "viewport-crop-scale-shm shm-viewport-crop-scale           1       1280  720    1000   3"
    "viewport-control-dmabuf dmabuf-full                       1       1280  720    1000   3"
    "viewport-crop-dmabuf dmabuf-viewport-crop                 1       1280  720    1000   3"
    "viewport-scale-dmabuf dmabuf-viewport-scale               1       1280  720    1000   3"
    "viewport-crop-scale-dmabuf dmabuf-viewport-crop-scale     1       1280  720    1000   3"
    "solid-shm             shm-solid-full                      1       1280  720    1000   3"
    "solid-dmabuf          dmabuf-solid-full                   1       1280  720    1000   3"
    "solid-single-pixel    single-pixel-full                   1       1280  720    1000   3"
    "dmabuf-dual-sparse   dmabuf-sparse                        2       640   720    1000   3"
    "dmabuf-static        dmabuf-static                        1       1280  720    1000   3"
    "dmabuf-scale-1       dmabuf-sparse                        1       640   360    1000   3"
    "dmabuf-scale-2       dmabuf-sparse                        2       640   360    1000   3"
    "dmabuf-scale-8       dmabuf-sparse                        8       640   360    1000   3"
    "dmabuf-scale-16      dmabuf-sparse                        16      640   360    1000   3"
    "dmabuf-scale-32      dmabuf-sparse                        32      640   360    1000   3"
    "dmabuf-scale-64      dmabuf-sparse                        64      640   360    1000   3"
    "dmabuf-churn         dmabuf-churn                         1       1280  720    300    3"
    "dmabuf-churn-2       dmabuf-churn                         2       640   360    300    3"
    "dmabuf-churn-8       dmabuf-churn                         8       640   360    300    3"
    "mixed-sparse         shm-sparse,dmabuf-sparse             2       640   720    1000   3"
    "mixed-scale-8        shm-sparse,shm-sparse,shm-sparse,shm-sparse,dmabuf-sparse,dmabuf-sparse,dmabuf-sparse,dmabuf-sparse 8 640 360 1000 3"
    "color-control-shm    shm-full                             1       1280  720    1000   3"
    "color-control-dmabuf dmabuf-full                          1       1280  720    1000   3"
    "color-control-scale-8 shm-full                            8       640   360    1000   3"
    "color-parametric-shm shm-color-parametric                 1       1280  720    1000   3"
    "color-icc-shm        shm-color-icc                        1       1280  720    1000   3"
    "color-icc-dmabuf     dmabuf-color-icc                     1       1280  720    1000   3"
    "color-icc-scale-8    shm-color-icc                        8       640   360    1000   3"
    "alpha-shm-full       shm-alpha-full                       1       1280  720    1000   3"
    "alpha-dmabuf-full    dmabuf-alpha-full                    1       1280  720    1000   3"
    "alpha-mixed-scale-8  shm-alpha-sparse,shm-alpha-sparse,shm-alpha-sparse,shm-alpha-sparse,dmabuf-alpha-sparse,dmabuf-alpha-sparse,dmabuf-alpha-sparse,dmabuf-alpha-sparse 8 640 360 1000 3"
    "layers-overlap-2     shm-overlap-2                        1       960   540    600    3"
    "layers-overlap-8     shm-overlap-8                        1       960   540    600    3"
    "layers-overlap-32    shm-overlap-32                       1       960   540    600    3"
    "layers-occlusion-8   shm-occlusion-8                      1       640   360    600    3"
    "layers-occlusion-32  shm-occlusion-32                     1       640   360    600    3"
)

benchmark_suite_contains() {
    local suite=$1 workload=$2
    case "$suite" in
        quick)
            [[ $workload == shm-full || $workload == shm-sparse ||
                $workload == dmabuf-full || $workload == dmabuf-sparse ||
                $workload == mixed-scale-8 ]]
            ;;
        standard)
            [[ $workload == shm-full || $workload == shm-tiny ||
                $workload == shm-sparse || $workload == shm-scale-8 ||
                $workload == shm-buffer-churn || $workload == dmabuf-full ||
                $workload == dmabuf-tiny || $workload == dmabuf-sparse ||
                $workload == dmabuf-scale-8 || $workload == dmabuf-churn ||
                $workload == mixed-scale-8 || $workload == color-parametric-shm ||
                $workload == color-icc-shm || $workload == alpha-shm-full ||
                $workload == alpha-dmabuf-full ]]
            ;;
        all) [[ $workload != *-scale-16 && $workload != *-scale-32 &&
            $workload != *-scale-64 ]] ;;
        shm) [[ $workload == shm-* && $workload != *-scale-16 && $workload != *-scale-32 && $workload != *-scale-64 ]] ;;
        dmabuf) [[ $workload == dmabuf-* && $workload != *-scale-16 && $workload != *-scale-32 && $workload != *-scale-64 ]] ;;
        damage) [[ $workload == *-moving || $workload == *-multirect-* ]] ;;
        viewport) [[ $workload == viewport-* ]] ;;
        solid) [[ $workload == solid-* ]] ;;
        scale) [[ $workload == *-scale-[128] ]] ;;
        churn) [[ $workload == *churn* ]] ;;
        mixed) [[ $workload == mixed-* ]] ;;
        color) [[ $workload == color-* ]] ;;
        composition) [[ $workload == alpha-* || $workload == layers-* ]] ;;
        layers) [[ $workload == layers-* ]] ;;
        capacity) [[ $workload == *-scale-16 || $workload == *-scale-32 ||
            $workload == *-scale-64 ]] ;;
        *) return 1 ;;
    esac
}
