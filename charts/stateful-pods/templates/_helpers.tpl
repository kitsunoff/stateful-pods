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
--------------------------------------------------------------------------------
Guest provisioning
--------------------------------------------------------------------------------

The backend a machine selects, the inputs each backend accepts, and how those
inputs are turned into the two things the pod needs: entries for the chart's own
Secret, and sources for the projected volume that assembles them.

Nothing here reads a value into script text. The provisioning step is handed a
directory of files with fixed names and never learns whether a file was written
from the values or projected from somebody else's Secret - which is what makes
"inline or reference" a property of the values rather than a branch in the code.
*/}}

{{/*
The inputs the cloud-init backend accepts, mapped to the file name each one is
materialized under.

The file names are the contract between the chart and the provisioning script.
They are deliberately not the field names: `user-data`, `network-config` and
`vendor-data` are cloud-init's own names for the seed files, and the rest follow
the same spelling so that one directory listing reads as one thing.

Takes no context. Emits YAML.
*/}}
{{- define "stateful-pods.provisioning.cloudInit.inputs" -}}
userData: user-data
networkConfig: network-config
vendorData: vendor-data
user: user
password: password
sshAuthorizedKeys: ssh-authorized-keys
packages: packages
runcmd: runcmd
packageUpgrade: package-upgrade
{{- end -}}

{{/*
The backend a machine is provisioned by.

`cloud-init` when the machine names none, per the design: it is what people
actually want, and what the images this project publishes carry. A value of the
wrong type resolves to the default here and is reported by the validation stage,
so that one mistake produces one message.

Takes (dict "root" $ "name" $name "machine" $machine).
*/}}
{{- define "stateful-pods.machine.provisioning.backend" -}}
{{- $guest := .machine.guest | default dict -}}
{{- $declared := "" -}}
{{- if kindIs "map" $guest -}}
{{- $declared = index $guest "provisioning" -}}
{{- end -}}
{{- if and (kindIs "string" $declared) (ne ($declared | toString) "") -}}
{{- $declared | toString -}}
{{- else -}}
cloud-init
{{- end -}}
{{- end -}}

{{/*
What a machine's provisioning inputs resolve to.

Emits YAML with three keys:

  backend  the backend name
  inline   file name -> content, for the chart's own Secret
  refs     one entry per referenced input, each with the file name it is
           projected to and the object and key it comes from

Validation has already run by the time anything calls this, so it assumes the
inputs are well formed. Rendering is deterministic: the catalog is a map, and
Helm iterates a map in key order.

Takes (dict "root" $ "name" $name "machine" $machine).
*/}}
{{- define "stateful-pods.machine.provisioning.resolved" -}}
{{- $backend := include "stateful-pods.machine.provisioning.backend" . -}}
{{- $inline := dict -}}
{{- $refs := list -}}
{{- if eq $backend "cloud-init" -}}
{{- $catalog := include "stateful-pods.provisioning.cloudInit.inputs" . | fromYaml -}}
{{- $given := .machine.cloudInit | default dict -}}
{{- if kindIs "map" $given -}}
{{- range $field, $path := $catalog -}}
{{- $input := index $given $field -}}
{{- if kindIs "map" $input -}}
{{- $value := index $input "value" -}}
{{- if not (kindIs "invalid" $value) -}}
{{- $_ := set $inline $path ($value | toString) -}}
{{- else -}}
{{- $from := index $input "valueFrom" | default dict -}}
{{- if kindIs "map" (index $from "secretKeyRef") -}}
{{- $ref := index $from "secretKeyRef" -}}
{{- $refs = append $refs (dict "path" $path "kind" "secret" "name" ($ref.name | toString) "key" ($ref.key | toString)) -}}
{{- else if kindIs "map" (index $from "configMapKeyRef") -}}
{{- $ref := index $from "configMapKeyRef" -}}
{{- $refs = append $refs (dict "path" $path "kind" "configMap" "name" ($ref.name | toString) "key" ($ref.key | toString)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{ toYaml (dict "backend" $backend "inline" $inline "refs" $refs) }}
{{- end -}}

{{/*
The name of the Secret the chart renders for a machine's inline material.

A machine of its own rather than one per release: the material belongs to the
machine, and a release that grows a second machine must not have to rename the
first one's Secret.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.provisioning.secretName" -}}
{{- printf "%s-provisioning" (include "stateful-pods.machine.name" .) -}}
{{- end -}}

{{/*
Whether a machine supplies any provisioning material at all.

Emits "true" or "". A machine that supplies nothing renders no Secret and no
volume - an empty projected volume would be a mount that carries nothing, and a
Secret with no keys would be an object nobody can explain.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.provisioning.hasMaterial" -}}
{{- $resolved := include "stateful-pods.machine.provisioning.resolved" . | fromYaml -}}
{{- if or $resolved.inline $resolved.refs -}}
true
{{- end -}}
{{- end -}}

{{/*
The digest that restarts a machine when its provisioning changes.

Over everything the chart can see: the backend, the inline material, the
references by name rather than by content, and the machine's own revision input.

The references are in it by name because a machine that stops reading one Secret
and starts reading another has changed even though neither Secret's content is
visible from here. What is not in it is what those Secrets hold, which is why the
revision input exists at all.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.provisioning.checksum" -}}
{{- $resolved := include "stateful-pods.machine.provisioning.resolved" . | fromYaml -}}
{{- $guest := .machine.guest | default dict -}}
{{- $revision := "" -}}
{{- if kindIs "map" $guest -}}
{{- $revision = index $guest "provisioningRevision" | default "" | toString -}}
{{- end -}}
{{- printf "%s\n%s" (toYaml $resolved) $revision | sha256sum -}}
{{- end -}}

{{/*
The environment the provisioning step reads, on top of the seeding environment
every step already gets.

The backend and the directory the material is mounted at. Nothing else: the
identity the instance is keyed on is composed by the script from SP_NAMESPACE,
SP_RELEASE and SP_MACHINE, which the seeding environment already carries.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.provisioning.env" -}}
- name: SP_PROVISIONING
  value: {{ include "stateful-pods.machine.provisioning.backend" . | quote }}
- name: SP_PROVISIONING_DIR
  value: /provisioning
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
The checks on one provisioning input: that it is supplied exactly one way, and
that the way it is supplied is complete.

Both forms present is not a preference the chart can resolve. Picking one would
mean the material the user believed was in effect is the one that was discarded,
and they would learn that from a machine that behaves wrongly rather than from a
message.

Takes (dict "field" $prefix "input" $input). Emits a YAML list of errors,
possibly empty.
*/}}
{{- define "stateful-pods.validate.valueSource" -}}
{{- $field := .field -}}
{{- $input := .input -}}
{{- $errors := list -}}
{{- if not (kindIs "map" $input) -}}
{{- $errors = append $errors (printf "%s: must be a map naming `value` or `valueFrom`, but is of type %s. Every provisioning input takes one of those two forms, so a bare scalar has to be given under `value`." $field (kindOf $input)) -}}
{{- else -}}
{{- $value := index $input "value" -}}
{{- $from := index $input "valueFrom" -}}
{{- $hasValue := not (kindIs "invalid" $value) -}}
{{- $hasFrom := not (kindIs "invalid" $from) -}}
{{- if and $hasValue $hasFrom -}}
{{- $errors = append $errors (printf "%s: carries both `value` and `valueFrom`. Supply exactly one: `value` puts the content in the values file and in the Helm release, `valueFrom` names a Secret or ConfigMap key so that it appears in neither." $field) -}}
{{- else if $hasValue -}}
{{- /* A Secret key is bytes, so both forms carry a string. Accepting a list
       here would make the two forms different shapes, which is the one property
       of this contract worth more than the convenience. */ -}}
{{- if not (kindIs "string" $value) -}}
{{- $errors = append $errors (printf "%s.value: must be a string, but is of type %s. A referenced Secret key is bytes, so the inline form carries a string too; give a list as a block scalar with one item per line." $field (kindOf $value)) -}}
{{- end -}}
{{- else if $hasFrom -}}
{{- if not (kindIs "map" $from) -}}
{{- $errors = append $errors (printf "%s.valueFrom: must be a map naming one source, but is of type %s. Accepted sources: secretKeyRef, configMapKeyRef." $field (kindOf $from)) -}}
{{- else -}}
{{- $named := list -}}
{{- range $source := list "secretKeyRef" "configMapKeyRef" -}}
{{- if not (kindIs "invalid" (index $from $source)) -}}
{{- $named = append $named $source -}}
{{- end -}}
{{- end -}}
{{- if gt (len $named) 1 -}}
{{- $errors = append $errors (printf "%s.valueFrom: names more than one source. Exactly one of secretKeyRef, configMapKeyRef, so that the content of an input has a single origin." $field) -}}
{{- else if eq (len $named) 0 -}}
{{- $errors = append $errors (printf "%s.valueFrom: names no source the chart accepts. Accepted sources: secretKeyRef, configMapKeyRef - a key in a Secret or in a ConfigMap in this release's namespace." $field) -}}
{{- else -}}
{{- $source := index $named 0 -}}
{{- $ref := index $from $source -}}
{{- $object := ternary "Secret" "ConfigMap" (eq $source "secretKeyRef") -}}
{{- if not (kindIs "map" $ref) -}}
{{- $errors = append $errors (printf "%s.valueFrom.%s: must be a map naming the %s and the key inside it, but is of type %s." $field $source $object (kindOf $ref)) -}}
{{- else -}}
{{- if eq (index $ref "name" | default "" | toString) "" -}}
{{- $errors = append $errors (printf "%s.valueFrom.%s.name: not set. Name the %s in this release's namespace that holds this input's content." $field $source $object) -}}
{{- end -}}
{{- if eq (index $ref "key" | default "" | toString) "" -}}
{{- $errors = append $errors (printf "%s.valueFrom.%s.key: not set. Name the key inside that %s whose content becomes this input." $field $source $object) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $errors = append $errors (printf "%s: names neither `value` nor `valueFrom`. Give the content inline under `value`, or name a Secret or ConfigMap key under `valueFrom`." $field) -}}
{{- end -}}
{{- end -}}
{{ toYaml $errors }}
{{- end -}}

{{/*
The checks on a machine's provisioning: the backend it names, and the inputs it
supplies for that backend.

An input belonging to a backend the machine did not select is an error rather
than something ignored. Silently ignoring it leaves the user believing the
machine is configured to do something it is not, which is the same class of
outcome as the silent no-op this whole capability exists to prevent.

Takes (dict "name" $name "machine" $machine). Emits a YAML list of errors,
possibly empty.
*/}}
{{- define "stateful-pods.validate.provisioning" -}}
{{- $name := .name -}}
{{- $machine := .machine -}}
{{- $errors := list -}}
{{- $backend := "cloud-init" -}}
{{- $backendKnown := true -}}
{{- $guest := $machine.guest | default dict -}}
{{- if kindIs "map" $guest -}}
{{- $declared := index $guest "provisioning" -}}
{{- if not (kindIs "invalid" $declared) -}}
{{- if not (kindIs "string" $declared) -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: must name a provisioning backend, but is of type %s. Accepted backends: cloud-init, native." $name (kindOf $declared)) -}}
{{- $backendKnown = false -}}
{{- else if eq ($declared | toString) "systemd-credentials" -}}
{{- /* Not a typo on the user's part. The design describes three backends, and
       telling someone who read it that the name is wrong would send them
       looking for the right spelling of something that is not there. */ -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: \"systemd-credentials\" is not implemented yet. The design describes it - credentials projected into a tmpfs at /run/host/credentials, so that nothing sensitive is written to the machine's volume - and this chart does not implement it. Accepted backends: cloud-init, native." $name) -}}
{{- $backendKnown = false -}}
{{- else if not (has ($declared | toString) (list "cloud-init" "native")) -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: %q is not a provisioning backend. Accepted backends: cloud-init, native. cloud-init writes a NoCloud seed into the machine and needs cloud-init in the image; native writes nothing beyond the files the chart already maintains and works with any image." $name ($declared | toString)) -}}
{{- $backendKnown = false -}}
{{- else -}}
{{- $backend = $declared | toString -}}
{{- end -}}
{{- end -}}
{{- $revision := index $guest "provisioningRevision" -}}
{{- if not (kindIs "invalid" $revision) -}}
{{- if not (or (kindIs "string" $revision) (kindIs "float64" $revision) (kindIs "int" $revision) (kindIs "int64" $revision)) -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioningRevision: must be a string or a number, but is of type %s. It is folded into the annotation that restarts a machine, and it exists for material the chart cannot see the content of - a referenced Secret that has rotated." $name (kindOf $revision)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- $given := index $machine "cloudInit" -}}
{{- if not (kindIs "invalid" $given) -}}
{{- if not (kindIs "map" $given) -}}
{{- $errors = append $errors (printf "machines.%s.cloudInit: must be a map of provisioning inputs, but is of type %s. Each input under it takes a `value` or a `valueFrom`." $name (kindOf $given)) -}}
{{- else if and $backendKnown (ne $backend "cloud-init") -}}
{{- $errors = append $errors (printf "machines.%s.cloudInit: belongs to the \"cloud-init\" backend, but this machine selected %q. Remove these inputs, or set machines.%s.guest.provisioning to \"cloud-init\"." $name $backend $name) -}}
{{- else -}}
{{- $catalog := include "stateful-pods.provisioning.cloudInit.inputs" . | fromYaml -}}
{{- range $field, $path := $catalog -}}
{{- $input := index $given $field -}}
{{- if not (kindIs "invalid" $input) -}}
{{- $errors = concat $errors (include "stateful-pods.validate.valueSource" (dict "field" (printf "machines.%s.cloudInit.%s" $name $field) "input" $input) | fromYamlArray) -}}
{{- end -}}
{{- end -}}
{{- /* Reported after the inputs that exist, so that a machine with a real
       mistake and a typo is told about the mistake first. */ -}}
{{- range $field, $input := $given -}}
{{- if kindIs "invalid" (index $catalog $field) -}}
{{- $errors = append $errors (printf "machines.%s.cloudInit.%s: is not an input of the \"cloud-init\" backend. Accepted inputs: %s." $name $field (join ", " (keys $catalog | sortAlpha))) -}}
{{- end -}}
{{- end -}}
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
{{- /* Not an input of any kind. `stateful-pods.machine.resolvedSource` sets this
       on the resolved source to carry the preset's name into the seeding
       environment, and `prepare.sh` records it. A value supplied here would be
       carried through as though the chart had resolved it, and the volume would
       assert a preset the machine was not made from - which is the one question
       the record exists to answer. */ -}}
{{- if not (kindIs "invalid" (index $source "preset")) -}}
{{- $errors = append $errors (printf "machines.%s.source.preset: is not an input. It is set by the chart when a \"preset\" source resolves, and it is what the machine's provisioning record names, so a value supplied here would make that record claim a preset the machine was not made from. Remove the field; to choose a preset, set machines.%s.source.kind to \"preset\" and name it in machines.%s.source.name." $name $name $name) -}}
{{- end -}}
{{- if eq $kind "" -}}
{{- $errors = append $errors (printf "machines.%s.source.kind: not set. Name the source kind explicitly, so that a mistyped field cannot silently change where the machine's root filesystem comes from. Accepted kinds: oci, lxc, preset." $name) -}}
{{- else if eq $kind "oci" -}}
{{- if eq ($source.reference | default "") "" -}}
{{- $errors = append $errors (printf "machines.%s.source.reference: not set. An \"oci\" source requires an image reference, for example docker.io/library/debian:13." $name) -}}
{{- end -}}
{{- range $pair := list (list "url" "lxc") (list "sha256" "lxc") (list "name" "preset") -}}
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
{{- range $pair := list (list "reference" "oci") (list "url" "lxc") (list "sha256" "lxc") -}}
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
{{- /* Requiring a checksum is not the same as requiring a checksum. The
       verification this input exists for happens in the guest, after the whole
       template has been fetched, so every malformed value that renders is a
       machine that downloads gigabytes and then crash-loops - and the value is
       checked here rather than there for exactly that reason.

       The check is on the string's shape and not on its YAML type, because the
       type is already lost. A checksum of sixty-four digits and no letters is a
       valid YAML number, so it is resolved to a float before any template
       function sees it; the `toString` above is not missing, and it faithfully
       renders 1.23...e+61. Anchoring on the shape catches that, the truncated
       paste, the uppercase digest that can never equal the lowercase one
       sha256sum prints, and the whole sha256sum line pasted with its filename -
       and keeps working if a future YAML library resolves the scalar
       differently. */ -}}
{{- else if not (regexMatch "^[0-9a-f]{64}$" ($source.sha256 | toString)) -}}
{{- $errors = append $errors (printf "machines.%s.source.sha256: %q is not a SHA-256 checksum. It must be exactly sixty-four lowercase hexadecimal characters. Quote the value: a checksum that happens to be all digits is read by YAML as a number, and what reaches the machine is the number in exponent form rather than the digest. The template is verified in the guest, after it has been downloaded in full, so a checksum that cannot match costs the whole fetch before it fails." $name ($source.sha256 | toString)) -}}
{{- end -}}
{{- range $pair := list (list "reference" "oci") (list "pullSecretName" "oci") (list "name" "preset") -}}
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

{{- /* How the machine is provisioned, and the inputs it supplies for it. */ -}}
{{- $errors = concat $errors (include "stateful-pods.validate.provisioning" (dict "name" $name "machine" $machine) | fromYamlArray) -}}

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
