#!/usr/bin/env bash
# Downloads a static BusyBox (linux/arm64) into this folder. It provides `sh` and `nc` for
# with-localhost-forwards.sh inside images that ship neither. Run once before "Stack Up".
set -euo pipefail
cd "$(dirname "$0")"
container run --rm -v "$PWD:/out" alpine:3.21 sh -c \
    'apk add --no-cache busybox-static >/dev/null && cp /bin/busybox.static /out/busybox && chmod 755 /out/busybox'
ls -l busybox
