# A syscall filter for a machine

`stateful-pods-machine.json` is a seccomp profile for the guest container — the one that becomes the
machine. The chart never installs it. It is a file that has to exist on every node a machine can be
scheduled to, and a machine names it:

```yaml
machines:
  web:
    security:
      mode: userns
      seccompProfile:
        type: Localhost
        localhostProfile: profiles/stateful-pods-machine.json
```

The path is relative to the kubelet's seccomp directory, `/var/lib/kubelet/seccomp` unless the
kubelet was told otherwise.

## Why it is a denylist

The profile applies to every process in the container, which after the root change means the
machine's own init and everything it starts. An allowlist would have to enumerate what an entire
distribution's userland calls, and would break the day a new systemd reached for a new system call.

So the default action is `SCMP_ACT_ALLOW`, and the profile denies five calls plus one argument. That
list is not this project's invention: it is `common.seccomp` from LXC, which is what every Proxmox
container in the world already runs under. That is the strongest available evidence that it does not
break a booting distribution.

| Denied | Capability it would need | What it would be used for |
| --- | --- | --- |
| `kexec_load` | `CAP_SYS_BOOT` | replacing the running kernel |
| `open_by_handle_at` | `CAP_DAC_READ_SEARCH` | reaching a file outside the container's root by handle |
| `init_module`, `finit_module`, `delete_module` | `CAP_SYS_MODULE` | loading or unloading kernel modules |
| `umount2` with `MNT_FORCE` | `CAP_SYS_ADMIN` | forcing a mount away underneath its users |

`architectures` lists the x86 and ARM ABIs so that a 32-bit process on a 64-bit node is filtered by
the same rules. Adding an architecture the node does not have is harmless; the node's own is always
part of the filter.

## What it is worth, per mode

In `userns` mode the capability set already denies all five calls, so the profile mostly restates a
boundary that exists. What it adds there is narrower: `CAP_SYS_ADMIN` inside a user namespace
unlocks a large amount of mount-related kernel code, and the kernel is the only target left. This
profile does not close that, and does not claim to.

In `privileged` mode the profile is not applied at all. Containerd drops the seccomp profile a
privileged container names before it builds the container — measured, not inferred — so no value the
chart sets can confine that mode.

## Getting the file onto the nodes

In the order they should be preferred.

**1. The Security Profiles Operator.** It exists for exactly this: a `SeccompProfile` custom
resource is reconciled onto every node, and the operator reports which nodes have it.
See <https://github.com/kubernetes-sigs/security-profiles-operator>.

**2. The node image, or whatever provisions the nodes.** Anyone who controls the image, the
ignition/cloud-init configuration or the configuration-management run that builds a node can put the
file in `/var/lib/kubelet/seccomp/profiles/` there. Nothing has to run in the cluster, and the file
is present before the kubelet is.

**3. A DaemonSet that writes the file.** It works, and it is worth naming honestly for what it is: a
workload with write access to the kubelet's own directory on every node, added in the name of
confinement. Prefer either of the two above where they are available.

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: seccomp-profile-installer
spec:
  selector:
    matchLabels:
      app: seccomp-profile-installer
  template:
    metadata:
      labels:
        app: seccomp-profile-installer
    spec:
      # The pod writes into the kubelet's own directory, which is why it needs a
      # host path at all. It runs once per node and then sleeps.
      initContainers:
        - name: install
          image: busybox:1.37
          command:
            - /bin/sh
            - -c
            - 'mkdir -p /host-seccomp/profiles && cp /profile/stateful-pods-machine.json /host-seccomp/profiles/'
          securityContext:
            runAsUser: 0
            allowPrivilegeEscalation: false
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: host-seccomp
              mountPath: /host-seccomp
            - name: profile
              mountPath: /profile
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          securityContext:
            allowPrivilegeEscalation: false
            seccompProfile:
              type: RuntimeDefault
      volumes:
        - name: host-seccomp
          hostPath:
            path: /var/lib/kubelet/seccomp
            type: DirectoryOrCreate
        - name: profile
          configMap:
            name: stateful-pods-machine-profile
```

The ConfigMap holds this directory's JSON file:

```bash
kubectl create configmap stateful-pods-machine-profile \
  --from-file charts/stateful-pods/profiles/stateful-pods-machine.json
```

## Checking that it took

A machine running under the profile denies the calls, and that is visible from inside it:

```bash
kubectl exec lab-web-0 -- sh -c 'cat /proc/1/status | grep Seccomp'
```

`Seccomp: 2` means a filter is loaded; `Seccomp: 0` means none is, which is what an unconfined
machine — and every privileged one — reports.
