#!/bin/sh
#
# Has this machine finished booting?
#
# This runs *inside the machine*, after the root change, so it may use only what
# an operating system provides. Nothing from the chart's image is reachable from
# here: that image is on the other side of the root change and its interpreter is
# gone. Hence POSIX sh, and hence no bash.
#
# The answer is derived from whatever init the machine turns out to run, so that
# no input ever has to declare it.
set -u

# systemd's own "am I booted" marker - the one sd_booted(3) tests.
if [ -d /run/systemd/system ]; then
    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
        running|degraded)
            # degraded counts: some unit failed, which is the machine's business
            # and not a reason to take it out of its Service.
            exit 0
            ;;
        *)
            exit 1
            ;;
    esac
fi

# OpenRC records the runlevel it reached.
if [ -f /run/openrc/softlevel ]; then
    exit 0
fi

# Any other init: the machine's own init has been started and has replaced the
# boot script. This is weaker than the two above - it says the operating system
# began, not that it finished - and it is the strongest signal an init that
# publishes nothing can give.
if [ -f /run/stateful-pods/booted ]; then
    exit 0
fi

exit 1
