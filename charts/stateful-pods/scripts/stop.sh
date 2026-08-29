#!/bin/sh
#
# Ask this machine to shut down, in the way its own init understands.
#
# Runs inside the machine, after the root change: POSIX sh, and nothing from the
# chart's image.
#
# SIGTERM to systemd means "re-execute yourself", not "shut down", so the signal
# Kubernetes sends by default would leave every machine to be killed when the
# grace period expired - an unclean shutdown of a pet on every ordinary delete.
# Sending systemd's shutdown signal unconditionally would be equally wrong:
# systemd's own container interface notes that only systemd reads it that way.
set -u

# The machine's init is PID 1. It is a variable so that the suite can send the
# signals to a process of its own and assert which one arrived, rather than
# asserting against a stub that a shell builtin would bypass anyway.
init_pid="${SP_INIT_PID:-1}"

if [ -d /run/systemd/system ]; then
    # SIGRTMIN+3 is poweroff. Some shells do not know the name, and the number is
    # 37 wherever glibc numbers the real-time signals, so try both.
    kill -s RTMIN+3 "$init_pid" 2>/dev/null \
        || kill -37 "$init_pid" 2>/dev/null \
        || kill -s TERM "$init_pid"
else
    kill -s TERM "$init_pid"
fi

# Wait for the machine to finish stopping, so that the pod is not reported as
# gone while its operating system is still writing to its disk. The cap is under
# the grace period, so the kubelet's own timeout is what ends an unresponsive
# machine rather than this loop returning early.
waited=0
limit="${SP_STOP_TIMEOUT:-110}"
while kill -0 "$init_pid" 2>/dev/null; do
    [ "$waited" -ge "$limit" ] && exit 0
    sleep 1
    waited=$((waited + 1))
done
exit 0
