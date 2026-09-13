## Why

The chart accepts two provisioning backends and refuses a third by name.
`systemd-credentials` was filed in the design as a mechanism that would keep provisioning material
off a machine's volume entirely, projected into a `tmpfs` at `/run/host/credentials` instead, and
the chart has carried a refusal saying so ever since — so that a reader who found it in the design
was told it is not built rather than that they had misspelled something.

It is not going to be built, and keeping the refusal is now the thing that misleads. It promises a
third backend to anyone who meets the message, and it is the one backend of the three that asks
something of the machine: `/run/host/credentials` is systemd's, so a machine running OpenRC, runit
or busybox init could never use it. The two that remain ask nothing of the init system —
`cloud-init` asks for cloud-init and says so loudly when it is absent, and `exec` asks for a shell —
and between them they cover every image this project ships a name for.

## What Changes

- **`systemd-credentials` stops being a name the chart knows.** It is refused as any other unknown
  backend is, listing the two that exist. **BREAKING** only in the sense that the message changes:
  the value has never been accepted.
- **The requirement that a designed-but-unimplemented backend is refused with its reason is
  removed**, from `guest-provisioning` and from `values-validation`. It described one value, that
  value is gone, and a requirement kept for nothing is a requirement that invents work later.
- **`values.yaml`, both READMEs and the specs** stop describing a third backend. What they say
  instead is why there are two: each asks something the other does not, and neither asks anything of
  the machine's init system.

Non-goals:

- **The research documents are left as they are.** `docs/research/` records what was investigated
  and when, including two backend names the chart no longer has; it is a dated record rather than
  the contract, and the contract is `openspec/specs/`. The same decision was made when `native`
  became `exec`.
- **Keeping material off the volume is not solved here and is not claimed to be.** The `exec`
  backend already places its script and environment on the machine's own `tmpfs` rather than its
  volume, which is the part of the idea that had a home; the rest of it went with the backend.
