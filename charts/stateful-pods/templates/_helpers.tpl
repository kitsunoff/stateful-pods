{{/*
The chart label value, e.g. stateful-pods-0.1.0.
Takes the root context.
*/}}
{{- define "stateful-pods.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
--------------------------------------------------------------------------------
Names and labels
--------------------------------------------------------------------------------

Every helper below takes an explicit machine context:

    (dict "root" $ "name" $name "machine" $machine)

and reads no `.Values` global to work out which machine it is describing. A helper
that reached for `.Values.machines` and picked the only entry would be correct
today and silently wrong the moment a release has two machines.
*/}}

{{/*
The object name for a machine: <release>-<machine>.

This name is permanent. The machine's root filesystem is a PersistentVolumeClaim
derived from it, so renaming orphans the volume and recreates the machine empty.
*/}}
{{- define "stateful-pods.machine.name" -}}
{{- printf "%s-%s" .root.Release.Name .name -}}
{{- end -}}

{{/*
Selector labels: the machine's identity, and nothing else.

A StatefulSet's spec.selector is immutable after creation, so anything that varies
between upgrades - a chart version, an app version, a release revision - must stay
out of here. Adding one would make the first `helm upgrade` fail with "field is
immutable", recoverable only by deleting the StatefulSet, which destroys the
machine.
*/}}
{{- define "stateful-pods.machine.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
stateful-pods.io/machine: {{ .name }}
{{- end -}}

{{/*
Object labels: the selector labels plus the labels that do change between
upgrades. Applied to object metadata and to the pod template, never to a selector.
*/}}
{{- define "stateful-pods.machine.labels" -}}
{{ include "stateful-pods.machine.selectorLabels" . }}
app.kubernetes.io/version: {{ .root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ include "stateful-pods.chart" .root }}
{{- end -}}

{{/*
The environment the seeding and preparation steps read.

Everything a script needs arrives this way. No value is ever interpolated into
script text, so a hostname, a URL or a reference containing shell metacharacters
is data to the script and never something it parses. The namespace comes from the
downward API rather than from `.Release.Namespace`, so a manifest applied into a
different namespace than it was rendered for still records where it actually ran.

Takes (dict "root" $ "name" $name "machine" $machine).
*/}}
{{- define "stateful-pods.machine.seedEnv" -}}
- name: SP_ROOTFS
  value: /mnt/rootfs
- name: SP_MACHINE
  value: {{ .name | quote }}
- name: SP_RELEASE
  value: {{ .root.Release.Name | quote }}
- name: SP_NAMESPACE
  valueFrom:
    fieldRef:
      fieldPath: metadata.namespace
- name: SP_CHART_VERSION
  value: {{ .root.Chart.Version | quote }}
- name: SP_SOURCE_KIND
  value: {{ .machine.source.kind | quote }}
{{- if eq .machine.source.kind "oci" }}
- name: SP_SOURCE_REFERENCE
  value: {{ .machine.source.reference | quote }}
{{- else }}
- name: SP_SOURCE_URL
  value: {{ .machine.source.url | quote }}
- name: SP_SOURCE_SHA256
  value: {{ .machine.source.sha256 | toString | quote }}
{{- end }}
{{- end -}}

{{/*
The security context of the steps that run before the guest.

The privilege a machine's mode names belongs to the guest container and to nothing
else. Preparing the contents of a volume is not privileged work: writing files
with their ownership and attributes intact is something an ordinary container
already does.

Running as the container's root user is not privilege in that sense - it is what
writing another system's file ownership requires, and under `userns` it is not
root on the node at all. It is stated rather than left to the image, so that the
posture a machine gets is the one the chart chose and not one a `shim.image`
override could change by declaring a user of its own.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.initSecurityContext" -}}
runAsUser: 0
runAsGroup: 0
allowPrivilegeEscalation: false
{{- end -}}

{{/*
--------------------------------------------------------------------------------
Validation
--------------------------------------------------------------------------------

Every template calls "stateful-pods.validate" before it renders anything, so the
same set of errors is reported no matter which file Helm renders first.

Validation runs in two stages. The structural stage checks the shape of the
machines map and fails on its own, because every semantic check below reads that
map and would otherwise pile a cascade of derived errors on top of one root
cause. The semantic stage accumulates every violation it finds and fails once
with the complete list, so that fixing one value does not merely reveal the next.
*/}}

{{- define "stateful-pods.validate" -}}
{{- include "stateful-pods.validate.structure" . -}}
{{- include "stateful-pods.validate.semantics" . -}}
{{- end -}}

{{/*
Renders the accumulated violations into the message passed to `fail`.
Takes (dict "errors" $listOfStrings).
*/}}
{{- define "stateful-pods.validate.report" -}}

stateful-pods: these values were rejected.

{{ join "\n\n" .errors }}

Nothing was rendered. Fix every item above and try again.
{{- end -}}

{{/*
Stage one: the shape of the machines map. Fails on its own so that a malformed
map does not produce a cascade of derived errors.
Takes the root context.
*/}}
{{- define "stateful-pods.validate.structure" -}}
{{- $errors := list -}}
{{- $machines := .Values.machines -}}
{{- if or (kindIs "invalid" $machines) (and (kindIs "map" $machines) (eq (len $machines) 0)) -}}
{{- $errors = append $errors (include "stateful-pods.errors.noMachines" .) -}}
{{- else if not (kindIs "map" $machines) -}}
{{- $errors = append $errors (printf "machines: must be a map keyed by machine name, but is of type %s. Declare each machine under its own name, not as a list." (kindOf $machines)) -}}
{{- else if gt (len $machines) 1 -}}
{{- $errors = append $errors (printf "machines: %d machines declared. Multiple machines per release are not implemented yet; give each machine its own Helm release for now. The map form is already in place, so nothing has to be renamed when the restriction is lifted." (len $machines)) -}}
{{- else -}}
{{- range $name, $machine := $machines -}}
{{- if not (kindIs "map" $machine) -}}
{{- $errors = append $errors (printf "machines.%s: must be a map of the machine's inputs, but is of type %s." $name (kindOf $machine)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $errors -}}
{{- fail (include "stateful-pods.validate.report" (dict "errors" $errors)) -}}
{{- end -}}
{{- end -}}

{{/*
Stage two: every remaining check, accumulated and reported together.
Takes the root context.
*/}}
{{- define "stateful-pods.validate.semantics" -}}
{{- $root := . -}}
{{- $errors := list -}}

{{- /* Chart-level inputs. */ -}}
{{- $shim := $root.Values.shim | default dict -}}
{{- if or (not (kindIs "map" $shim)) (eq ($shim.image | default "") "") -}}
{{- $errors = append $errors "shim.image: not set. It is the image of the shim that mounts the machine's root filesystem, and it is never the machine's own operating system. Leave the chart default in place unless you are building your own shim." -}}
{{- end -}}
{{- range $key := list "replicas" "replicaCount" -}}
{{- if not (kindIs "invalid" (index $root.Values $key)) -}}
{{- $errors = append $errors (printf "%s: not supported. A machine is a single instance by definition, because a second copy would mount the same root filesystem. Declare further machines under `machines` instead." $key) -}}
{{- end -}}
{{- end -}}

{{- range $name, $machine := $root.Values.machines -}}
{{- $objectName := printf "%s-%s" $root.Release.Name $name -}}

{{- /* The machine name becomes part of every object name, so it is checked first. */ -}}
{{- if or (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) (gt (len $name) 63) -}}
{{- $errors = append $errors (printf "machines.%s: %q is not a valid machine name. A machine name must be a DNS-1123 label: at most 63 lowercase alphanumeric characters or '-', starting and ending with an alphanumeric character." $name $name) -}}
{{- else if gt (len $objectName) 61 -}}
{{- $errors = append $errors (printf "machines.%s: the object name %q is %d characters, %d over the 61-character limit (63 minus the \"-0\" StatefulSet ordinal suffix, which becomes the pod's hostname). Shorten the release name or the machine name." $name $objectName (len $objectName) (sub (len $objectName) 61)) -}}
{{- end -}}

{{- /* Security mode: mandatory, explicit, and never inferred from the cluster. */ -}}
{{- $security := $machine.security | default dict -}}
{{- $mode := "" -}}
{{- if kindIs "map" $security -}}
{{- $mode = $security.mode | default "" -}}
{{- end -}}
{{- if eq $mode "" -}}
{{- $errors = append $errors (printf "machines.%s.security.mode: not set. Choose the privilege level this machine runs with; there is no default, because the chart will not weaken a machine's isolation on your behalf. Accepted modes:\n%s" $name (include "stateful-pods.errors.modeLadder" $root)) -}}
{{- else if not (has $mode (list "userns" "privileged")) -}}
{{- $errors = append $errors (printf "machines.%s.security.mode: %q is not a supported mode. Accepted modes: userns, privileged." $name $mode) -}}
{{- else if eq $mode "userns" -}}
{{- $found := $root.Capabilities.KubeVersion.Version -}}
{{- if not (semverCompare ">= 1.33.0-0" $found) -}}
{{- $errors = append $errors (printf "machines.%s.security.mode: \"userns\" requires Kubernetes >= 1.33, but the target cluster reports %s. Upgrade the cluster, or set machines.%s.security.mode to \"privileged\", which works on any cluster and gives up almost all isolation." $name $found $name) -}}
{{- end -}}
{{- end -}}

{{- /* The rootfs source: kind named explicitly, never inferred from the fields present. */ -}}
{{- $source := $machine.source -}}
{{- if kindIs "invalid" $source -}}
{{- $errors = append $errors (printf "machines.%s.source: not declared. Declare where this machine's root filesystem is seeded from at machines.%s.source, naming its kind explicitly. Accepted kinds: oci, lxc." $name $name) -}}
{{- else if not (kindIs "map" $source) -}}
{{- $errors = append $errors (printf "machines.%s.source: must be a map naming the source kind and its fields, but is of type %s. Accepted kinds: oci, lxc." $name (kindOf $source)) -}}
{{- else -}}
{{- $kind := $source.kind | default "" -}}
{{- if eq $kind "" -}}
{{- $errors = append $errors (printf "machines.%s.source.kind: not set. Name the source kind explicitly, so that a mistyped field cannot silently change where the machine's root filesystem comes from. Accepted kinds: oci, lxc." $name) -}}
{{- else if eq $kind "oci" -}}
{{- if eq ($source.reference | default "") "" -}}
{{- $errors = append $errors (printf "machines.%s.source.reference: not set. An \"oci\" source requires an image reference, for example docker.io/library/debian:13." $name) -}}
{{- end -}}
{{- range $field := list "url" "sha256" -}}
{{- if not (kindIs "invalid" (index $source $field)) -}}
{{- $errors = append $errors (printf "machines.%s.source.%s: does not belong to source kind \"oci\"; it belongs to kind \"lxc\". Remove the field, or set machines.%s.source.kind to \"lxc\"." $name $field $name) -}}
{{- end -}}
{{- end -}}
{{- /* The credentials for a private source are named, never spelled out: a value
       is stored in the release, printed by `helm get values` and usually
       committed, so a credential that can be put there will be. */ -}}
{{- $pullSecret := index $source "pullSecretName" -}}
{{- if not (kindIs "invalid" $pullSecret) -}}
{{- if eq ($pullSecret | toString) "" -}}
{{- $errors = append $errors (printf "machines.%s.source.pullSecretName: is empty. Name the Secret in this release's namespace that holds the registry credentials, or remove the field entirely to fetch the source anonymously." $name) -}}
{{- else if or (gt (len ($pullSecret | toString)) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" ($pullSecret | toString))) -}}
{{- $errors = append $errors (printf "machines.%s.source.pullSecretName: %q is not a valid Secret name. It must be a DNS-1123 subdomain: at most 253 lowercase alphanumeric characters, '-' or '.', with each dot-separated part starting and ending with an alphanumeric character." $name ($pullSecret | toString)) -}}
{{- end -}}
{{- end -}}
{{- else if eq $kind "lxc" -}}
{{- if eq ($source.url | default "") "" -}}
{{- $errors = append $errors (printf "machines.%s.source.url: not set. An \"lxc\" source requires the HTTPS URL of the template tarball, for example https://download.proxmox.com/images/system/debian-13-standard_13.0-1_amd64.tar.zst." $name) -}}
{{- end -}}
{{- if eq ($source.sha256 | default "" | toString) "" -}}
{{- $errors = append $errors (printf "machines.%s.source.sha256: not set. An \"lxc\" source requires the SHA-256 checksum of the template tarball, and there is no way to skip verification. The tarball is fetched over the network and unpacked into what becomes a privileged machine's root filesystem, and nothing about the transport establishes that the bytes are the intended ones." $name) -}}
{{- end -}}
{{- range $field := list "reference" "pullSecretName" -}}
{{- if not (kindIs "invalid" (index $source $field)) -}}
{{- $errors = append $errors (printf "machines.%s.source.%s: does not belong to source kind \"lxc\"; it belongs to kind \"oci\". Remove the field, or set machines.%s.source.kind to \"oci\"." $name $field $name) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $errors = append $errors (printf "machines.%s.source.kind: %q is not a supported source kind. Accepted kinds: oci, lxc." $name $kind) -}}
{{- end -}}
{{- end -}}

{{- /* Inputs the design considered and rejected. Silently ignoring them would
       leave the user believing the machine is configured to do something it is not. */ -}}
{{- range $field := list "replicas" "replicaCount" -}}
{{- if not (kindIs "invalid" (index $machine $field)) -}}
{{- $errors = append $errors (printf "machines.%s.%s: not supported. A machine is a single instance by definition, because a second copy would mount the same root filesystem. Declare further machines under `machines` instead." $name $field) -}}
{{- end -}}
{{- end -}}
{{- if not (kindIs "invalid" (index $machine "init")) -}}
{{- $errors = append $errors (printf "machines.%s.init: not supported. The shim runs /sbin/init and detects the guest's init system at boot, so there is nothing to select. Remove this input." $name) -}}
{{- end -}}
{{- $guest := $machine.guest | default dict -}}
{{- if and (kindIs "map" $guest) (not (kindIs "invalid" (index $guest "init"))) -}}
{{- $errors = append $errors (printf "machines.%s.guest.init: not supported. The shim runs /sbin/init and detects the guest's init system at boot, so there is nothing to select. Remove this input." $name) -}}
{{- end -}}

{{- end -}}

{{- if $errors -}}
{{- fail (include "stateful-pods.validate.report" (dict "errors" $errors)) -}}
{{- end -}}
{{- end -}}

{{/*
The message shown when a machine declares no security mode. It doubles as the
documentation of the two modes, which is why it states what each needs.
*/}}
{{- define "stateful-pods.errors.modeLadder" }}
      userns     - the pod runs in its own user namespace (hostUsers: false) and the guest
                   container is granted CAP_SYS_ADMIN, which is void on the host because it
                   is scoped to that namespace. Requires Kubernetes >= 1.33 with user
                   namespaces enabled, containerd >= 2.0 or CRI-O, Linux >= 6.3 and
                   idmap-capable storage (not NFS).
      privileged - the guest container runs privileged. Works on any cluster and on any
                   kernel, and gives up almost all isolation from the node.
{{- end -}}

{{- define "stateful-pods.errors.noMachines" -}}
machines: no machines declared. Exactly one machine must be declared, keyed by its name:

      machines:
        web:
          source:
            kind: oci
            reference: docker.io/library/debian:13
          security:
            mode: userns
          rootfs:
            size: 8Gi
{{- end -}}
