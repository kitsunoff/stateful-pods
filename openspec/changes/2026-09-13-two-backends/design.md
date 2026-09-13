## Context

`guest.provisioning` accepts `cloud-init` and `exec`. A third name, `systemd-credentials`, has never
been accepted and has always been refused with a message of its own: not "unknown backend" but "the
design describes it and this chart does not implement it".

That message was right when it was written. The design named three backends, somebody reading it
would reasonably type the third, and telling them the name was wrong would have sent them hunting
for a spelling that did not exist.

## Goals

- The set of backends a reader can discover is the set the chart has.
- The reason there are two is written down where the choice is made, so that the absence of a third
  is a decision rather than a gap.

## Non-goals

See the proposal: the research documents keep their own record, and nothing here claims to solve
keeping provisioning material off a machine's volume.

## Decisions

### The third backend goes rather than waits

Two things changed since the refusal was written.

The first is that `exec` arrived. The gap `systemd-credentials` was filed against was a machine that
cannot run cloud-init, and the answer to that is now a backend that asks nothing of the image at all.

The second is that the third backend is the only one that would have asked something of the machine's
**init system**. `/run/host/credentials` is systemd's mechanism; a machine running OpenRC, runit or
busybox init could never have used it, and two of the four presets this project publishes do not run
systemd. A chart whose backends are chosen for being agnostic would have carried one that was not.

So the name stops being special. A machine that declares it is told the same thing a machine that
declares `ansible` is told: that is not a backend, here are the two that are.

### What the documentation says instead

Not "there used to be a third". The place where a backend is chosen now says why there are two, in
terms of what each asks for:

| Backend | Asks the image for | Asks the init system for |
| --- | --- | --- |
| `cloud-init` | cloud-init, and fails the pod loudly when it is absent | nothing — systemd units and OpenRC scripts are both recognised |
| `exec` | a shell | nothing |

That is the property worth recording, and it is the one that decided this. A reader who wants to know
why there is no third backend finds the answer in what the two have in common.

### The requirement goes with it

`values-validation` carried a requirement that a designed-but-unimplemented backend is refused with
its reason, and `guest-provisioning` carried the scenario. Both described exactly one value.

They are removed rather than generalised. A requirement kept against a future value nobody has named
is a requirement that invents work the first time somebody reads it literally — and the general form
of it is already there: an unknown backend is refused and the accepted ones are listed.
