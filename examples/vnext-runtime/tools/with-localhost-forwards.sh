#!/fw/busybox sh
# Entrypoint wrapper: bridges `localhost:<port>` inside this container to another container,
# then starts the real process.
#
# Workflow components written for a runtime that runs on the developer's machine call
# http://localhost:3001 (MockLab) or http://localhost:4201 (the runtime itself). Inside a
# container `localhost` is the container, and on Apple Container two containers cannot share
# a network namespace — so the ports are forwarded here.
#
#   LOCALHOST_FORWARDS="3001:mocklab:5000 4201:vnext-app-core:5000"
for spec in ${LOCALHOST_FORWARDS:-}; do
    port="${spec%%:*}"
    target="${spec#*:}"
    /fw/busybox nc -lk -p "$port" -e /fw/busybox nc "${target%%:*}" "${target#*:}" &
done
exec "$@"
