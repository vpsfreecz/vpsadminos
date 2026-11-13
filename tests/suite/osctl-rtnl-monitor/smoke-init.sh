#!/bin/busybox sh
trap 'exit 0' INT TERM PWR
while :; do
  /bin/busybox sleep 1 &
  wait "$!"
done
