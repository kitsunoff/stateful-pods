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
--------------------------------------------------------------------------------
The preset catalog
--------------------------------------------------------------------------------
*/}}

{{/*
The table of presets this chart ships, as a map from name to a digest-pinned
image reference. Takes the root context.

It lives in presets.yaml at the chart root rather than in values.yaml for two
reasons. It is data a bot maintains rather than configuration a user sets, and
every key in values.yaml has to carry a comment explaining itself, which is noise
on a generated table. `.Files` reaches chart-root files inside a packaged chart,
so the table travels with the chart however it is installed - which a values file
usable only from a checkout would not.
*/}}
{{- define "stateful-pods.presets" -}}
{{- .Files.Get "presets.yaml" -}}
{{- end -}}

{{/*
The preset names, sorted, as a comma-separated list for an error message.
Takes the root context.

Generated from the table rather than written out beside it: a list maintained by
hand would be wrong the first time a preset was added, and it would be wrong in
the one place a user reads when they already have something wrong.
*/}}
{{- define "stateful-pods.presets.names" -}}
{{- keys (include "stateful-pods.presets" . | fromYaml) | sortAlpha | join ", " -}}
{{- end -}}

{{/*
The machine's source with a preset resolved to what it names.

A preset is a name for an image, so it resolves to the `oci` kind and the rest of
the chart never learns that presets exist: the seeding path is the one that was
already there, and no script gains a branch. The name is carried alongside as
`preset`, because a volume that recorded only a digest could not answer which
preset the machine was made from a year later, when the answer matters most.

Resolution happens here, at render time, and nowhere later. A name resolved after
rendering would mean a machine's source could differ between the manifest the
user reviewed and the pod that ran.

Takes (dict "root" $ "name" $name "machine" $machine). Emits YAML.
*/}}
{{- define "stateful-pods.machine.resolvedSource" -}}
{{- $source := .machine.source -}}
{{- if eq ($source.kind | default "") "preset" -}}
{{- $catalog := include "stateful-pods.presets" .root | fromYaml -}}
kind: oci
reference: {{ index $catalog ($source.name | toString) | quote }}
preset: {{ $source.name | quote }}
{{- $pullSecret := index $source "pullSecretName" }}
{{- if not (kindIs "invalid" $pullSecret) }}
pullSecretName: {{ $pullSecret | quote }}
{{- end }}
{{- else -}}
{{ toYaml $source }}
{{- end -}}
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
{{- $source := include "stateful-pods.machine.resolvedSource" . | fromYaml -}}
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
  value: {{ $source.kind | quote }}
{{- if eq $source.kind "oci" }}
- name: SP_SOURCE_REFERENCE
  value: {{ $source.reference | quote }}
{{- if $source.preset }}
- name: SP_SOURCE_PRESET
  value: {{ $source.preset | quote }}
{{- end }}
{{- else }}
- name: SP_SOURCE_URL
  value: {{ $source.url | quote }}
- name: SP_SOURCE_SHA256
  value: {{ $source.sha256 | toString | quote }}
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

The syscall filter is the runtime's own default. These steps unpack an archive,
write files and fetch over HTTPS; they mount nothing and change no root, so
nothing the default profile withholds is in their way. Unlike the guest's filter
it needs no file to be present on any node, which makes it the one narrowing
this chart can apply to every install without an operator doing anything first.
It is named here rather than left unset for the same reason the mode is named: a
kubelet configured to supply a default is a posture the machine's values do not
describe.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.initSecurityContext" -}}
runAsUser: 0
runAsGroup: 0
allowPrivilegeEscalation: false
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
The syscall filter the guest container declares.

`Unconfined` unless the machine names something else, and declared either way.
Leaving the field out would hand the choice to the kubelet: one configured with
`--seccomp-default=true` supplies the runtime's default profile to every
container that names none, and that profile does not permit `pivot_root` - the
call this container makes to become the machine. The machine would seed its
volume and then die at the root change, on some clusters and not others.

The only form that can confine a machine is `Localhost`, because the filter has
to permit an entire distribution's userland and no default profile does. The
file it names lives on the node, which is outside anything a chart can create -
see `profiles/stateful-pods-machine.json` and the chart README for the ways to
get one there.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.guestSeccompProfile" -}}
{{- $security := .machine.security | default dict -}}
{{- $profile := dict "type" "Unconfined" -}}
{{- if kindIs "map" $security -}}
{{- if kindIs "map" (index $security "seccompProfile") -}}
{{- $profile = index $security "seccompProfile" -}}
{{- end -}}
{{- end -}}
seccompProfile:
  type: {{ $profile.type | toString | quote }}
{{- if eq ($profile.type | toString) "Localhost" }}
  localhostProfile: {{ $profile.localhostProfile | toString | quote }}
{{- end }}
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
The checks on a source's registry credentials, shared by every kind that fetches
from a registry.

The credentials are named, never spelled out: a value is stored in the release,
printed by `helm get values` and usually committed, so a credential that can be
put there will be.

A preset needs these as much as an `oci` source does. A preset is a name for a
reference this project pins; it is not a promise that the registry serving it
will hand it to anyone who asks.

Takes (dict "name" $name "source" $source). Emits a YAML list of errors, possibly
empty.
*/}}
{{- define "stateful-pods.validate.pullSecretName" -}}
{{- $name := .name -}}
{{- $errors := list -}}
{{- $pullSecret := index .source "pullSecretName" -}}
{{- if not (kindIs "invalid" $pullSecret) -}}
{{- if not (kindIs "string" $pullSecret) -}}
{{- $errors = append $errors (printf "machines.%s.source.pullSecretName: must be the name of a Secret, but is of type %s. Name a single Secret in this release's namespace - and quote it if the name is one YAML reads as something else, such as an unquoted no, off or a number." $name (kindOf $pullSecret)) -}}
{{- else if eq ($pullSecret | toString) "" -}}
{{- $errors = append $errors (printf "machines.%s.source.pullSecretName: is empty. Name the Secret in this release's namespace that holds the registry credentials, or remove the field entirely to fetch the source anonymously." $name) -}}
{{- else if or (gt (len ($pullSecret | toString)) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" ($pullSecret | toString))) -}}
{{- $errors = append $errors (printf "machines.%s.source.pullSecretName: %q is not a valid Secret name. It must be a DNS-1123 subdomain: at most 253 lowercase alphanumeric characters, '-' or '.', with each dot-separated part starting and ending with an alphanumeric character." $name ($pullSecret | toString)) -}}
{{- end -}}
{{- end -}}
{{ toYaml $errors }}
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
{{- $errors = append $errors (printf "machines.%s.security.mode: \"userns\" requires Kubernetes >= 1.33, but the target cluster reports %s. Upgrade the cluster, or set machines.%s.security.mode to \"privileged\", which asks nothing of the cluster beyond this chart's floor of 1.30 and grants the guest a named capability set that is real on the node." $name $found $name) -}}
{{- end -}}
{{- end -}}

{{- /* The syscall filter, optional. The chart declares one for every container, so
       this is the machine's chance to replace the guest's - and the one value of it
       that is known to produce an unbootable machine is refused rather than
       rendered. */ -}}
{{- if kindIs "map" $security -}}
{{- $seccomp := index $security "seccompProfile" -}}
{{- if not (kindIs "invalid" $seccomp) -}}
{{- if not (kindIs "map" $seccomp) -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile: must be a map naming the filter form, but is of type %s. Accepted forms:\n%s" $name (kindOf $seccomp) (include "stateful-pods.errors.seccompForms" $root)) -}}
{{- else -}}
{{- $type := $seccomp.type | default "" | toString -}}
{{- /* The path is read before the form, because a path that is not a string
       cannot be checked for shape and would otherwise be reported twice - once
       for its type and again for a shape derived from it. */ -}}
{{- $rawPath := index $seccomp "localhostProfile" -}}
{{- $profilePath := "" -}}
{{- $pathIsUsable := true -}}
{{- if not (kindIs "invalid" $rawPath) -}}
{{- if kindIs "string" $rawPath -}}
{{- $profilePath = $rawPath -}}
{{- else -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.localhostProfile: must be the path of a profile file on the node, but is of type %s. A path is a string - quote it if it is one YAML reads as something else. A value that is not one renders into the manifest, is accepted by the API server and fails in the kubelet, which surfaces as a machine that never starts a container." $name (kindOf $rawPath)) -}}
{{- $pathIsUsable = false -}}
{{- end -}}
{{- end -}}
{{- if eq $type "" -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.type: not set. Name the filter form explicitly, the same way the mode is named. Accepted forms:\n%s" $name (include "stateful-pods.errors.seccompForms" $root)) -}}
{{- else if eq $type "RuntimeDefault" -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.type: \"RuntimeDefault\" cannot be used for a machine. The container runtime's default profile does not permit pivot_root, which is the call the guest container makes to become the machine, so this value renders cleanly, seeds the volume over several minutes and then fails at the root change. That holds in both modes: neither of them renders a container the runtime has been told to stop policing, so both get the filter they name. A filter that does permit it has to come from a file on the node: place one and name it with type \"Localhost\" and machines.%s.security.seccompProfile.localhostProfile. This chart ships such a profile in profiles/stateful-pods-machine.json." $name $name) -}}
{{- else if not (has $type (list "Unconfined" "Localhost")) -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.type: %q is not a syscall filter form. Accepted forms:\n%s" $name $type (include "stateful-pods.errors.seccompForms" $root)) -}}
{{- end -}}
{{- if not $pathIsUsable -}}
{{- /* Already reported above; anything derived from it would be noise. */ -}}
{{- else if eq $type "Localhost" -}}
{{- if eq $profilePath "" -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.localhostProfile: not set. The \"Localhost\" form names a profile file the cluster has placed on its nodes, so it needs the path of one - relative to the kubelet's seccomp directory, which is /var/lib/kubelet/seccomp unless the kubelet was told otherwise. For example: profiles/stateful-pods-machine.json." $name) -}}
{{- else if or (hasPrefix "/" $profilePath) (has ".." (splitList "/" $profilePath)) -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.localhostProfile: %q must be a relative path, descending from the kubelet's seccomp directory. The kubelet resolves it under that directory itself, so an absolute path or one containing \"..\" is rejected by the API server, which surfaces as a machine that never starts a container. Give the part below the directory, for example profiles/stateful-pods-machine.json." $name $profilePath) -}}
{{- end -}}
{{- else if and (ne $profilePath "") (has $type (list "Unconfined" "RuntimeDefault")) -}}
{{- $errors = append $errors (printf "machines.%s.security.seccompProfile.localhostProfile: does not belong to filter form %q; only \"Localhost\" names a profile file. Remove the field, or set machines.%s.security.seccompProfile.type to \"Localhost\"." $name $type $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* The rootfs source: kind named explicitly, never inferred from the fields present. */ -}}
{{- $source := $machine.source -}}
{{- if kindIs "invalid" $source -}}
{{- $errors = append $errors (printf "machines.%s.source: not declared. Declare where this machine's root filesystem is seeded from at machines.%s.source, naming its kind explicitly. Accepted kinds: oci, lxc, preset." $name $name) -}}
{{- else if not (kindIs "map" $source) -}}
{{- $errors = append $errors (printf "machines.%s.source: must be a map naming the source kind and its fields, but is of type %s. Accepted kinds: oci, lxc, preset." $name (kindOf $source)) -}}
{{- else -}}
{{- $kind := $source.kind | default "" -}}
{{- if eq $kind "" -}}
{{- $errors = append $errors (printf "machines.%s.source.kind: not set. Name the source kind explicitly, so that a mistyped field cannot silently change where the machine's root filesystem comes from. Accepted kinds: oci, lxc, preset." $name) -}}
{{- else if eq $kind "oci" -}}
{{- if eq ($source.reference | default "") "" -}}
{{- $errors = append $errors (printf "machines.%s.source.reference: not set. An \"oci\" source requires an image reference, for example docker.io/library/debian:13." $name) -}}
{{- end -}}
{{- range $pair := list (list "url" "lxc") (list "sha256" "lxc") (list "name" "preset") (list "preset" "preset") -}}
{{- $field := index $pair 0 -}}
{{- if not (kindIs "invalid" (index $source $field)) -}}
{{- $errors = append $errors (printf "machines.%s.source.%s: does not belong to source kind \"oci\"; it belongs to kind %q. Remove the field, or set machines.%s.source.kind to %q." $name $field (index $pair 1) $name (index $pair 1)) -}}
{{- end -}}
{{- end -}}
{{- $errors = concat $errors (include "stateful-pods.validate.pullSecretName" (dict "name" $name "source" $source) | fromYamlArray) -}}
{{- else if eq $kind "preset" -}}
{{- /* A name for a reference this project pins and verified the provenance of.
       The point of it is that the user does not have to research a reference, so
       a typo that rendered anyway - resolving to nothing, or to a default - would
       hand back exactly the debugging session the preset exists to avoid. */ -}}
{{- $presetNames := include "stateful-pods.presets.names" $root -}}
{{- $presetName := index $source "name" -}}
{{- if kindIs "invalid" $presetName -}}
{{- $errors = append $errors (printf "machines.%s.source.name: not set. A \"preset\" source names one of the root filesystems this chart ships a pinned, provenance-verified reference for. Available presets: %s." $name $presetNames) -}}
{{- else if not (or (kindIs "string" $presetName) (kindIs "float64" $presetName) (kindIs "int" $presetName) (kindIs "int64" $presetName)) -}}
{{- $errors = append $errors (printf "machines.%s.source.name: must be the name of a preset, but is of type %s. Available presets: %s." $name (kindOf $presetName) $presetNames) -}}
{{- else if eq ($presetName | toString) "" -}}
{{- $errors = append $errors (printf "machines.%s.source.name: is empty. Name one of the root filesystems this chart ships. Available presets: %s." $name $presetNames) -}}
{{- else if kindIs "invalid" (index (include "stateful-pods.presets" $root | fromYaml) ($presetName | toString)) -}}
{{- $errors = append $errors (printf "machines.%s.source.name: %q is not a preset this chart ships. Available presets: %s. A preset resolves to a reference this project publishes; to use an image of your own, set machines.%s.source.kind to \"oci\" and give the reference directly." $name ($presetName | toString) $presetNames $name) -}}
{{- end -}}
{{- /* A preset already is a reference, a verified checksum and an upstream. A
       user who also supplies one of those has expressed two intentions, and the
       one that would be silently discarded may be the one they believed was in
       effect. */ -}}
{{- range $pair := list (list "reference" "oci") (list "url" "lxc") (list "sha256" "lxc") (list "preset" "preset") -}}
{{- $field := index $pair 0 -}}
{{- if not (kindIs "invalid" (index $source $field)) -}}
{{- $errors = append $errors (printf "machines.%s.source.%s: does not belong to source kind \"preset\"; it belongs to kind %q. A preset is a name for a reference this project pins and verified the provenance of, so it takes neither a reference nor a checksum of its own. Remove the field, or set machines.%s.source.kind to %q." $name $field (index $pair 1) $name (index $pair 1)) -}}
{{- end -}}
{{- end -}}
{{- $errors = concat $errors (include "stateful-pods.validate.pullSecretName" (dict "name" $name "source" $source) | fromYamlArray) -}}
{{- else if eq $kind "lxc" -}}
{{- if eq ($source.url | default "") "" -}}
{{- $errors = append $errors (printf "machines.%s.source.url: not set. An \"lxc\" source requires the HTTPS URL of the template tarball, for example https://download.proxmox.com/images/system/debian-13-standard_13.0-1_amd64.tar.zst." $name) -}}
{{- end -}}
{{- if eq ($source.sha256 | default "" | toString) "" -}}
{{- $errors = append $errors (printf "machines.%s.source.sha256: not set. An \"lxc\" source requires the SHA-256 checksum of the template tarball, and there is no way to skip verification. The tarball is fetched over the network and unpacked into what becomes a privileged machine's root filesystem, and nothing about the transport establishes that the bytes are the intended ones." $name) -}}
{{- end -}}
{{- range $pair := list (list "reference" "oci") (list "pullSecretName" "oci") (list "name" "preset") (list "preset" "preset") -}}
{{- $field := index $pair 0 -}}
{{- if not (kindIs "invalid" (index $source $field)) -}}
{{- $errors = append $errors (printf "machines.%s.source.%s: does not belong to source kind \"lxc\"; it belongs to kind %q. Remove the field, or set machines.%s.source.kind to %q." $name $field (index $pair 1) $name (index $pair 1)) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $errors = append $errors (printf "machines.%s.source.kind: %q is not a supported source kind. Accepted kinds: oci, lxc, preset." $name $kind) -}}
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
      privileged - the guest container is granted a named capability set - what a container
                   gets by default, plus CAP_SYS_ADMIN for the mount and the root change -
                   and every one of them is real on the node. Asks nothing of the cluster
                   beyond this chart's own floor of Kubernetes 1.30, and nothing at all of
                   the kernel. It is not the runtime's blanket privileged flag: a machine in
                   this mode cannot load kernel modules, perform raw I/O, set the node's
                   clock or reach a device the pod was not given, and it does run under the
                   syscall filter its values name.
{{- end -}}

{{/*
The forms a machine's syscall filter may take. It doubles as the documentation of
them, which is why it states what each one costs the operator.
*/}}
{{- define "stateful-pods.errors.seccompForms" }}
      Unconfined - no syscall filter. The default, and the only form under which a machine
                   boots with nothing placed on the node: every runtime default profile
                   withholds pivot_root, which the guest container needs to become the
                   machine.
      Localhost  - the profile file named by
                   machines.<name>.security.seccompProfile.localhostProfile, which the
                   kubelet resolves under its own seccomp directory. That file has to be on
                   every node the machine can be scheduled to, and putting it there is not
                   something a chart can do - see the chart README.
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
