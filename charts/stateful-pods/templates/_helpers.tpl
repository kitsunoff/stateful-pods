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
{{- $catalog := dict -}}
{{- $given := dict -}}
{{- if eq $backend "cloud-init" -}}
{{- $catalog = include "stateful-pods.provisioning.cloudInit.inputs" . | fromYaml -}}
{{- $given = .machine.cloudInit | default dict -}}
{{- else if eq $backend "exec" -}}
{{- /* The same machinery, a different catalog. A script and an environment are
       material in the sense the cloud-init inputs are, so they arrive under
       fixed file names by the same route and the thing that reads them cannot
       tell an inline value from a projected Secret key. */ -}}
{{- $catalog = include "stateful-pods.provisioning.exec.inputs" . | fromYaml -}}
{{- $given = .machine.exec | default dict -}}
{{- end -}}
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
The inputs the exec backend accepts as material, mapped to the file name each one
is materialized under.

Two of them, and they are material in the sense the cloud-init inputs are: they
carry content that may want to be named rather than spelled out. The rest of the
backend's inputs - the interpreter, the budget, the retry count - are plain
scalars, because nobody needs to keep a timeout out of a values file.

Takes no context. Emits YAML.
*/}}
{{- define "stateful-pods.provisioning.exec.inputs" -}}
script: script
environment: environment
{{- end -}}

{{/*
The inputs the exec backend accepts that are not material.
*/}}
{{- define "stateful-pods.provisioning.exec.settings" -}}
interpreter timeoutSeconds retries
{{- end -}}

{{/*
The name of the identity the exec Job acts under: the ServiceAccount, the Role
and the RoleBinding all share it, because they are one grant and separating their
names would make the grant harder to read rather than easier.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.exec.name" -}}
{{- printf "%s-exec" (include "stateful-pods.machine.name" .) -}}
{{- end -}}

{{/*
The name of the Job that runs a machine's script.

The digest is of everything the chart can see about what would run - the
material as it was resolved, the references by name, and the machine's own
revision input - which is exactly the digest the cloud-init backend restarts a
machine on. Here it names an object instead.

That is the whole of the re-run policy, and it falls out of Helm's own semantics
rather than being enforced anywhere: an unchanged script is the same name and the
same content, so an upgrade is a no-op; a changed one is a different name, so the
old Job is removed and a new one is created and runs; and an uninstall takes both
with it. A Job's specification is immutable once it exists, so a name that stayed
the same while its script changed would make `helm upgrade` fail with `field is
immutable`.

Eight hexadecimal characters, which with the `-exec-` infix is the fourteen the
validation stage holds a machine's object name to when it supplies a script: a
Job's name may not exceed 63 characters, because the controller puts it in a
label.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.exec.jobName" -}}
{{- printf "%s-exec-%s" (include "stateful-pods.machine.name" .) (include "stateful-pods.machine.provisioning.checksum" . | trunc 8) -}}
{{- end -}}

{{/*
Whether a machine on the exec backend supplies a script.

Emits "true" or "". A machine that supplies none renders no Job, no
ServiceAccount, no Role and no RoleBinding, and is provisioned exactly as the
`native` backend it replaced always was.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.exec.hasScript" -}}
{{- if eq (include "stateful-pods.machine.provisioning.backend" .) "exec" -}}
{{- $resolved := include "stateful-pods.machine.provisioning.resolved" . | fromYaml -}}
{{- if index $resolved.inline "script" -}}
true
{{- else -}}
{{- range $ref := $resolved.refs -}}
{{- if eq $ref.path "script" -}}
true
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The exec backend's non-material settings, with their defaults applied.

Takes the same machine context as the other helpers. Emits YAML.
*/}}
{{- define "stateful-pods.machine.exec.settings" -}}
{{- $given := .machine.exec | default dict -}}
{{- $interpreter := "/bin/sh" -}}
{{- $timeout := 1800 -}}
{{- $retries := 0 -}}
{{- if kindIs "map" $given -}}
{{- $declared := index $given "interpreter" -}}
{{- if and (kindIs "string" $declared) (ne ($declared | toString) "") -}}
{{- $interpreter = $declared | toString -}}
{{- end -}}
{{- if not (kindIs "invalid" (index $given "timeoutSeconds")) -}}
{{- $timeout = index $given "timeoutSeconds" | int64 -}}
{{- end -}}
{{- if not (kindIs "invalid" (index $given "retries")) -}}
{{- $retries = index $given "retries" | int64 -}}
{{- end -}}
{{- end -}}
interpreter: {{ $interpreter | quote }}
timeoutSeconds: {{ $timeout }}
retries: {{ $retries }}
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
The network a machine is reachable on
--------------------------------------------------------------------------------

What the cluster is told about a machine, and never what the machine's own
interface is configured with - the pod's addressing belongs to the CNI, which is
why `values.yaml` refuses the Proxmox options that would set it.
*/}}

{{/*
The protocols a declared port may name. Kubernetes accepts exactly these three
for a container port and for a Service port, so the list is theirs rather than
this chart's.
*/}}
{{- define "stateful-pods.network.protocols" -}}
TCP UDP SCTP
{{- end -}}

{{/*
The inputs one port entry accepts, so that the refusal of anything else can list
them rather than merely reject.
*/}}
{{- define "stateful-pods.network.portInputs" -}}
port protocol
{{- end -}}

{{/*
The inputs the network block accepts.
*/}}
{{- define "stateful-pods.network.inputs" -}}
ports ingress egress
{{- end -}}

{{/*
A machine's declared ports, normalised: one entry per port, with the name it was
declared under, its number, and its protocol defaulted to TCP.

Sorted by name, because Helm iterates a map in key order and the rendered list
must not reorder itself when an unrelated value changes - a container port list
that permutes between renders is a pod the StatefulSet controller replaces for no
reason anyone can see in the diff.

Validation has already run by the time this is called, so it assumes the entries
are well formed.

Takes (dict "root" $ "name" $name "machine" $machine). Emits a YAML list.
*/}}
{{- define "stateful-pods.machine.ports" -}}
{{- $ports := list -}}
{{- $network := .machine.network | default dict -}}
{{- if kindIs "map" $network -}}
{{- $given := index $network "ports" | default dict -}}
{{- if kindIs "map" $given -}}
{{- range $name := keys $given | sortAlpha -}}
{{- $entry := index $given $name -}}
{{- if kindIs "map" $entry -}}
{{- $ports = append $ports (dict "name" ($name | toString) "port" (index $entry "port" | int64) "protocol" (index $entry "protocol" | default "TCP" | toString)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{ toYaml $ports }}
{{- end -}}

{{/*
The ingress posture a machine declares: `any` unless it says otherwise.

`any` renders no policy and changes nothing, which is what a chart upgrade must
do to a running pet's traffic. A value of the wrong type resolves to the default
here and is reported by the validation stage, so that one mistake produces one
message.

Takes the same machine context as the other helpers.
*/}}
{{- define "stateful-pods.machine.network.ingress" -}}
{{- $network := .machine.network | default dict -}}
{{- $declared := "" -}}
{{- if kindIs "map" $network -}}
{{- $declared = index $network "ingress" -}}
{{- end -}}
{{- if and (kindIs "string" $declared) (ne ($declared | toString) "") -}}
{{- $declared | toString -}}
{{- else -}}
any
{{- end -}}
{{- end -}}

{{/*
--------------------------------------------------------------------------------
The volumes a machine has beside its root filesystem
--------------------------------------------------------------------------------

A machine's root filesystem is the machine, and it is declared under `rootfs`.
Everything here is the storage beside it: the data a machine would want to keep
when its operating system is rebuilt, on its own claim, at its own size, on its
own class.
*/}}

{{/*
The inputs one volume entry accepts, so that the refusal of anything else can
list them rather than merely reject.
*/}}
{{- define "stateful-pods.volume.inputs" -}}
mountPath size storageClassName dataSource existingClaim readOnly
{{- end -}}

{{/*
The paths the boot sequence mounts over inside the machine, after the pod's own
volumes are in place. A declared volume at or under one of these is provisioned,
bound, mounted and then covered: it exists, it is empty on every start, and
nothing anywhere says why - so the chart refuses them.

/.stateful-pods is not mounted over; it is where the record that says the volume
has been seeded lives, and a volume over it would make every start look like a
first one.
*/}}
{{- define "stateful-pods.volume.reservedPaths" -}}
/proc /sys /dev /run /tmp /.stateful-pods
{{- end -}}

{{/*
The volume names the pod already uses for purposes of its own, which a declared
volume may not take. The machine's own object name is reserved too, and is
checked separately because it is not a constant.
*/}}
{{- define "stateful-pods.volume.reservedNames" -}}
source-credentials provisioning
{{- end -}}

{{/*
A machine's declared volumes, normalised: one entry per volume, carrying the name
it was declared under, the path it appears at inside the machine, whether the
chart provisions it, and everything the pod spec needs either way.

Ordered by mount path rather than by name, so that a volume declared inside
another's path is mounted after it. A parent path is a prefix of its children, so
sorting the paths puts the parent first; sorting by name would not, and the
kubelet passes a container's mounts to the runtime in the order they appear.

Validation has already run by the time this is called, so it assumes the entries
are well formed.

Takes (dict "root" $ "name" $name "machine" $machine). Emits a YAML list.
*/}}
{{- define "stateful-pods.machine.volumes" -}}
{{- $volumes := list -}}
{{- $given := .machine.volumes | default dict -}}
{{- if kindIs "map" $given -}}
{{- $byPath := dict -}}
{{- range $name := keys $given | sortAlpha -}}
{{- $entry := index $given $name -}}
{{- if kindIs "map" $entry -}}
{{- $claim := index $entry "existingClaim" | default "" | toString -}}
{{- $class := index $entry "storageClassName" -}}
{{- $path := index $entry "mountPath" | default "" | toString -}}
{{- $volume := dict "name" ($name | toString) "mountPath" $path "readOnly" (index $entry "readOnly" | default false) "provisioned" (eq $claim "") "claim" $claim "size" (index $entry "size" | default "" | toString) "hasClass" (not (kindIs "invalid" $class)) "storageClassName" (ternary ($class | toString) "" (not (kindIs "invalid" $class))) "snapshot" (dig "dataSource" "volumeSnapshotName" "" $entry | default "" | toString) -}}
{{- $_ := set $byPath (printf "%s %s" $path ($name | toString)) $volume -}}
{{- end -}}
{{- end -}}
{{- range $key := keys $byPath | sortAlpha -}}
{{- $volumes = append $volumes (index $byPath $key) -}}
{{- end -}}
{{- end -}}
{{ toYaml $volumes }}
{{- end -}}

{{/*
--------------------------------------------------------------------------------
What a machine may reach
--------------------------------------------------------------------------------

The outbound half of the network block. A rule is matched by a proxy in the
machine's own pod, which is what lets one be written as a name rather than as an
address - and the proxy is why the layers a rule can match on are the layers a
connection actually exposes.
*/}}

{{/*
The forms a rule may take, and the input that selects each. Exactly one per rule:
a rule matching on two layers at once would be a rule whose refusals nobody could
predict.
*/}}
{{- define "stateful-pods.egress.matchers" -}}
serverNames cidrs http
{{- end -}}

{{/*
The inputs one egress rule accepts.
*/}}
{{- define "stateful-pods.egress.ruleInputs" -}}
name ports protocol serverNames cidrs http
{{- end -}}

{{/*
The inputs the egress block accepts.
*/}}
{{- define "stateful-pods.egress.inputs" -}}
default rules
{{- end -}}

{{/*
The inputs an `http` matcher accepts.
*/}}
{{- define "stateful-pods.egress.httpInputs" -}}
authority pathPrefix
{{- end -}}

{{/*
The ports Envoy listens on and is administered through, inside the machine's own
pod. Not inputs: they are the chart's own numbers, and a machine that wanted to
serve one of them would be declaring a port the proxy already holds - which the
validation stage refuses, naming both.
*/}}
{{- define "stateful-pods.egress.proxyPort" -}}15001{{- end -}}
{{- define "stateful-pods.egress.adminPort" -}}15000{{- end -}}

{{/*
The user the proxy runs as. The redirect exempts it by exactly this number, which
is what keeps the proxy's own outbound connections from being redirected back
into itself.
*/}}
{{- define "stateful-pods.egress.proxyUser" -}}1337{{- end -}}

{{/*
A machine's egress policy, normalised.

Emits YAML with:

  declared  "true" when the machine declares one at all
  default   deny | allow
  rules     one entry per rule, with `kind` naming the form it took and its
            ports as a list of numbers

Ordered as the machine wrote them, because a policy is read in the order it was
written and reordering it would make a rendered manifest disagree with the values
it came from.

Validation has already run by the time this is called.

Takes (dict "root" $ "name" $name "machine" $machine).
*/}}
{{- define "stateful-pods.machine.egress" -}}
{{- $network := .machine.network | default dict -}}
{{- $given := dict -}}
{{- if kindIs "map" $network -}}
{{- $given = index $network "egress" | default dict -}}
{{- end -}}
{{- if or (not (kindIs "map" $given)) (eq (len $given) 0) -}}
declared: false
default: allow
rules: []
{{- else -}}
{{- $rules := list -}}
{{- range $rule := index $given "rules" | default list -}}
{{- if kindIs "map" $rule -}}
{{- $ports := list -}}
{{- range $port := index $rule "ports" | default list -}}
{{- $ports = append $ports ($port | int64) -}}
{{- end -}}
{{- $kind := "" -}}
{{- if not (kindIs "invalid" (index $rule "serverNames")) -}}
{{- $kind = "serverNames" -}}
{{- else if not (kindIs "invalid" (index $rule "http")) -}}
{{- $kind = "http" -}}
{{- else -}}
{{- $kind = "cidrs" -}}
{{- end -}}
{{- $http := index $rule "http" | default dict -}}
{{- $rules = append $rules (dict
      "name" (index $rule "name" | toString)
      "protocol" (index $rule "protocol" | default "TCP" | toString)
      "kind" $kind
      "ports" $ports
      "serverNames" (index $rule "serverNames" | default list)
      "cidrs" (index $rule "cidrs" | default list)
      "authority" (index $http "authority" | default "" | toString)
      "pathPrefix" (index $http "pathPrefix" | default "/" | toString)) -}}
{{- end -}}
{{- end -}}
{{ toYaml (dict "declared" true "default" (index $given "default" | default "deny" | toString) "rules" $rules) }}
{{- end -}}
{{- end -}}

{{/*
The name of the ConfigMap holding a machine's proxy configuration.
*/}}
{{- define "stateful-pods.machine.egress.configName" -}}
{{- printf "%s-egress" (include "stateful-pods.machine.name" .) -}}
{{- end -}}

{{/*
The digest that replaces a machine's pod when its egress policy changes.

The configuration is a ConfigMap, and a ConfigMap's content changing does not
restart anything on its own. Unlike the provisioning material, this one is
entirely visible to Helm - there is no reference form for a firewall rule - so
the digest is over the whole policy and is exact.
*/}}
{{- define "stateful-pods.machine.egress.checksum" -}}
{{- include "stateful-pods.machine.egress" . | sha256sum -}}
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

Takes (dict "objectName" $objectName "name" $name "machine" $machine). Emits a
YAML list of errors, possibly empty.
*/}}
{{- define "stateful-pods.validate.provisioning" -}}
{{- $name := .name -}}
{{- $objectName := .objectName -}}
{{- $machine := .machine -}}
{{- $errors := list -}}
{{- $backend := "cloud-init" -}}
{{- $backendKnown := true -}}
{{- $guest := $machine.guest | default dict -}}
{{- if kindIs "map" $guest -}}
{{- $declared := index $guest "provisioning" -}}
{{- if not (kindIs "invalid" $declared) -}}
{{- if not (kindIs "string" $declared) -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: must name a provisioning backend, but is of type %s. Accepted backends: cloud-init, exec." $name (kindOf $declared)) -}}
{{- $backendKnown = false -}}
{{- else if eq ($declared | toString) "systemd-credentials" -}}
{{- /* Not a typo on the user's part. The design describes three backends, and
       telling someone who read it that the name is wrong would send them
       looking for the right spelling of something that is not there. */ -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: \"systemd-credentials\" is not implemented yet. The design describes it - credentials projected into a tmpfs at /run/host/credentials, so that nothing sensitive is written to the machine's volume - and this chart does not implement it. Accepted backends: cloud-init, exec." $name) -}}
{{- $backendKnown = false -}}
{{- else if eq ($declared | toString) "native" -}}
{{- /* Not a typo either. `native` was this backend under its old name, back
       when it was defined by writing nothing; it runs a machine's own script
       inside the machine now, which is not that, so the name moved with the
       behaviour rather than quietly coming to mean something else. */ -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: \"native\" was renamed to \"exec\". It is the same backend and then some: with no script supplied it writes nothing into the machine, exactly as native did, and with machines.%s.exec.script supplied it runs that script inside the machine once the machine has booted. Set machines.%s.guest.provisioning to \"exec\"." $name $name $name) -}}
{{- $backendKnown = false -}}
{{- else if not (has ($declared | toString) (list "cloud-init" "exec")) -}}
{{- $errors = append $errors (printf "machines.%s.guest.provisioning: %q is not a provisioning backend. Accepted backends: cloud-init, exec. cloud-init writes a NoCloud seed into the machine and needs cloud-init in the image; exec asks nothing of the image and runs the machine's own script inside it after it has booted." $name ($declared | toString)) -}}
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

{{- /* The exec backend's own inputs. Two of them carry material and take the
       same two forms every provisioning input takes; the rest are plain
       scalars, because nobody needs to keep a timeout out of a values file. */ -}}
{{- $exec := index $machine "exec" -}}
{{- if not (kindIs "invalid" $exec) -}}
{{- $catalog := include "stateful-pods.provisioning.exec.inputs" . | fromYaml -}}
{{- $settings := splitList " " (include "stateful-pods.provisioning.exec.settings" .) -}}
{{- if not (kindIs "map" $exec) -}}
{{- $errors = append $errors (printf "machines.%s.exec: must be a map of the exec backend's inputs, but is of type %s. Accepted inputs: %s." $name (kindOf $exec) (join ", " (concat (keys $catalog) $settings | sortAlpha))) -}}
{{- else if and $backendKnown (ne $backend "exec") -}}
{{- $errors = append $errors (printf "machines.%s.exec: belongs to the \"exec\" backend, but this machine selected %q. Remove these inputs, or set machines.%s.guest.provisioning to \"exec\"." $name $backend $name) -}}
{{- else -}}
{{- range $field, $path := $catalog -}}
{{- $input := index $exec $field -}}
{{- if not (kindIs "invalid" $input) -}}
{{- $errors = concat $errors (include "stateful-pods.validate.valueSource" (dict "field" (printf "machines.%s.exec.%s" $name $field) "input" $input) | fromYamlArray) -}}
{{- end -}}
{{- end -}}

{{- $interpreter := index $exec "interpreter" -}}
{{- if not (kindIs "invalid" $interpreter) -}}
{{- if not (kindIs "string" $interpreter) -}}
{{- $errors = append $errors (printf "machines.%s.exec.interpreter: must be the path of a program inside the machine, but is of type %s." $name (kindOf $interpreter)) -}}
{{- else if not (hasPrefix "/" ($interpreter | toString)) -}}
{{- $errors = append $errors (printf "machines.%s.exec.interpreter: %q is not an absolute path. It is resolved inside the machine, where this chart's own PATH means nothing, so give the whole path: /bin/sh, /bin/bash, /usr/bin/python3." $name ($interpreter | toString)) -}}
{{- end -}}
{{- end -}}

{{- $timeout := index $exec "timeoutSeconds" -}}
{{- if not (kindIs "invalid" $timeout) -}}
{{- if or (kindIs "string" $timeout) (not (regexMatch "^[0-9]+$" ($timeout | toString))) (le (int64 $timeout) 0) -}}
{{- $errors = append $errors (printf "machines.%s.exec.timeoutSeconds: %v is not a number of seconds. It must be a whole number greater than zero, unquoted, and it covers the whole of the run - waiting for the machine to boot and running the script, together." $name $timeout) -}}
{{- end -}}
{{- end -}}

{{- $retries := index $exec "retries" -}}
{{- if not (kindIs "invalid" $retries) -}}
{{- if or (kindIs "string" $retries) (not (regexMatch "^[0-9]+$" ($retries | toString))) -}}
{{- $errors = append $errors (printf "machines.%s.exec.retries: %v is not a number of retries. It must be a whole number of zero or more, unquoted. Zero is the default, because re-running a provisioning script that failed half way is a decision only its author can make." $name $retries) -}}
{{- end -}}
{{- end -}}

{{- range $field, $input := $exec -}}
{{- if and (kindIs "invalid" (index $catalog $field)) (not (has $field $settings)) -}}
{{- $errors = append $errors (printf "machines.%s.exec.%s: is not an input of the \"exec\" backend. Accepted inputs: %s." $name $field (join ", " (concat (keys $catalog) $settings | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- /* The Job that runs the script is named from the machine's object name plus
       a fourteen-character suffix, and a Job's name may not exceed 63
       characters because the controller puts it in a label. This is the same
       refusal the object name already gets, with the budget this backend
       spends. */ -}}
{{- if kindIs "map" (index $exec "script") -}}
{{- $jobName := printf "%s-exec-00000000" $objectName -}}
{{- if gt (len $jobName) 63 -}}
{{- $errors = append $errors (printf "machines.%s: the Job that would run this machine's script is named %q, which is %d characters, %d over the 63-character limit a Job's name has - the controller puts it in a label, and a label value stops there. The suffix is the chart's: \"-exec-\" and eight characters of a digest that makes an unchanged script a no-op and a changed one a new run. Shorten the release name or the machine name, or supply no script." $name $jobName (len $jobName) (sub (len $jobName) 63)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{ toYaml $errors }}
{{- end -}}

{{/*
The checks on a machine's network block: the ports it declares and the ingress
posture it asks for.

Every one of these is a manifest the API server would reject on apply. A port
name it refuses, a number it refuses and a duplicate pair all surface as a
StatefulSet that renders cleanly and never creates a pod, with a message about a
field index rather than about a machine - so they are refused here, naming the
machine, the input and the rule.

Takes (dict "name" $name "machine" $machine). Emits a YAML list of errors,
possibly empty.
*/}}
{{- define "stateful-pods.validate.network" -}}
{{- $name := .name -}}
{{- $machine := .machine -}}
{{- $errors := list -}}
{{- $network := index $machine "network" -}}
{{- if not (kindIs "invalid" $network) -}}
{{- if not (kindIs "map" $network) -}}
{{- $errors = append $errors (printf "machines.%s.network: must be a map of this machine's network inputs, but is of type %s. Accepted inputs: %s. It describes what the cluster is told about the machine - never what the machine's own interface is configured with, which belongs to the cluster's CNI." $name (kindOf $network) (join ", " (splitList " " (include "stateful-pods.network.inputs" .) | sortAlpha))) -}}
{{- else -}}
{{- $accepted := splitList " " (include "stateful-pods.network.inputs" .) -}}
{{- range $field, $value := $network -}}
{{- if not (has $field $accepted) -}}
{{- $errors = append $errors (printf "machines.%s.network.%s: is not an input of the network block. Accepted inputs: %s." $name $field (join ", " ($accepted | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- /* The posture, before the ports, because a machine that asks for an
       enforcement the chart does not offer has a different problem from one
       whose port list is wrong. */ -}}
{{- $ingress := index $network "ingress" -}}
{{- if not (kindIs "invalid" $ingress) -}}
{{- if not (kindIs "string" $ingress) -}}
{{- $errors = append $errors (printf "machines.%s.network.ingress: must name an ingress posture, but is of type %s. Accepted postures:\n%s" $name (kindOf $ingress) (include "stateful-pods.errors.ingressPostures" .)) -}}
{{- else if not (has ($ingress | toString) (list "any" "declared")) -}}
{{- $errors = append $errors (printf "machines.%s.network.ingress: %q is not an ingress posture. Accepted postures:\n%s" $name ($ingress | toString) (include "stateful-pods.errors.ingressPostures" .)) -}}
{{- end -}}
{{- end -}}

{{- $ports := index $network "ports" -}}
{{- if not (kindIs "invalid" $ports) -}}
{{- if not (kindIs "map" $ports) -}}
{{- $errors = append $errors (printf "machines.%s.network.ports: must be a map keyed by port name, but is of type %s. The key is the name the port is published under - it appears in the Service's SRV record and in `kubectl describe pod` - so each port is declared under its own name rather than as an item in a list." $name (kindOf $ports)) -}}
{{- else -}}
{{- $protocols := splitList " " (include "stateful-pods.network.protocols" .) -}}
{{- $portInputs := splitList " " (include "stateful-pods.network.portInputs" .) -}}
{{- $seen := dict -}}
{{- range $portName := keys $ports | sortAlpha -}}
{{- $field := printf "machines.%s.network.ports.%s" $name $portName -}}
{{- $entry := index $ports $portName -}}
{{- /* The name first: it is the key, so every message below quotes it, and a
       key the API will refuse makes the rest academic. The rule is the
       Kubernetes IANA_SVC_NAME rule, stated rather than shown as a pattern. */ -}}
{{- if gt (len $portName) 15 -}}
{{- $errors = append $errors (printf "%s: %q is %d characters, and a port name is at most fifteen characters. Kubernetes validates a port name strictly - at most fifteen characters, lowercase letters, digits and hyphens, at least one letter, no leading, trailing or consecutive hyphens - and a name outside that is rejected by the API server, which surfaces as a machine whose pod is never created." $field $portName (len $portName)) -}}
{{- else if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $portName) -}}
{{- $errors = append $errors (printf "%s: %q is not a port name Kubernetes accepts. It must be at most fifteen characters of lowercase letters, digits and hyphens, starting and ending with a letter or a digit." $field $portName) -}}
{{- else if not (regexMatch "[a-z]" $portName) -}}
{{- $errors = append $errors (printf "%s: %q has no letter in it, and a port name must contain at least one. A name of digits alone is rejected by the API server, because it could not be told apart from a port number." $field $portName) -}}
{{- else if contains "--" $portName -}}
{{- $errors = append $errors (printf "%s: %q contains consecutive hyphens, which a port name may not." $field $portName) -}}
{{- end -}}
{{- if not (kindIs "map" $entry) -}}
{{- $errors = append $errors (printf "%s: must be a map naming the port number, but is of type %s. Accepted inputs: %s. The number goes under `port` rather than beside the name, so that a protocol can be named next to it." $field (kindOf $entry) (join ", " ($portInputs | sortAlpha))) -}}
{{- else -}}
{{- range $key, $value := $entry -}}
{{- if not (has $key $portInputs) -}}
{{- $errors = append $errors (printf "%s.%s: is not an input of a port. Accepted inputs: %s." $field $key (join ", " ($portInputs | sortAlpha))) -}}
{{- end -}}
{{- end -}}
{{- $number := index $entry "port" -}}
{{- $numberUsable := false -}}
{{- if kindIs "invalid" $number -}}
{{- $errors = append $errors (printf "%s.port: not set. A declared port needs the number it is served on." $field) -}}
{{- else if or (kindIs "string" $number) (not (regexMatch "^[0-9]+$" ($number | toString))) -}}
{{- /* The shape rather than the YAML type, for the reason the checksum check
       gives: a quoted number is a string and renders into the manifest as one,
       where the API server refuses it, and a fractional one is a float that
       renders in whatever form Go prints it. Both are the same mistake to the
       person making it. */ -}}
{{- $errors = append $errors (printf "%s.port: %v is not a port number. It must be a whole number between 1 and 65535, unquoted: the API server takes an integer here, so a quoted value renders as a string and is refused on apply." $field $number) -}}
{{- else if or (lt (int64 $number) 1) (gt (int64 $number) 65535) -}}
{{- $errors = append $errors (printf "%s.port: %v is outside the range of a port. It must be a whole number between 1 and 65535." $field $number) -}}
{{- else -}}
{{- $numberUsable = true -}}
{{- end -}}
{{- $protocol := index $entry "protocol" -}}
{{- $protocolUsable := true -}}
{{- if not (kindIs "invalid" $protocol) -}}
{{- if not (kindIs "string" $protocol) -}}
{{- $errors = append $errors (printf "%s.protocol: must name a protocol, but is of type %s. Accepted protocols: %s." $field (kindOf $protocol) (join ", " ($protocols | sortAlpha))) -}}
{{- $protocolUsable = false -}}
{{- else if not (has ($protocol | toString) $protocols) -}}
{{- $errors = append $errors (printf "%s.protocol: %q is not a protocol a port may name. Accepted protocols: %s. This is the transport, not the application protocol - a port serving HTTP names TCP." $field ($protocol | toString) (join ", " ($protocols | sortAlpha))) -}}
{{- $protocolUsable = false -}}
{{- end -}}
{{- end -}}
{{- /* The duplicate check last, and only on entries whose number and protocol
       both came out usable: a pair derived from a value already reported would
       collide with every other broken entry and bury the real message. */ -}}
{{- if and $numberUsable $protocolUsable -}}
{{- $pair := printf "%d/%s" (int64 $number) ($protocol | default "TCP" | toString) -}}
{{- $already := index $seen $pair -}}
{{- if $already -}}
{{- $errors = append $errors (printf "%s: declares %s, which machines.%s.network.ports.%s already declares. Two ports may share a number only on different protocols, so one of these is a duplicate the API server would refuse." $field $pair $name $already) -}}
{{- else -}}
{{- $_ := set $seen $pair $portName -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{ toYaml $errors }}
{{- end -}}
{{/*
The checks on a machine's declared volumes.

Two kinds of mistake are caught here, and the second is why this is worth as much
code as it takes. One kind renders a manifest the API server refuses on apply - a
name that is not a label, a size that is not a quantity - and surfaces as a
StatefulSet that never creates a pod. The other renders a manifest everything
accepts and produces a machine whose volume is silently empty for the rest of its
life: a volume mounted under a path the boot sequence covers is provisioned,
bound, mounted and then hidden, and it works in every observable way except the
one it was created for.

Takes (dict "objectName" $objectName "name" $name "machine" $machine). Emits a
YAML list of errors, possibly empty.
*/}}
{{- define "stateful-pods.validate.volumes" -}}
{{- $name := .name -}}
{{- $objectName := .objectName -}}
{{- $machine := .machine -}}
{{- $errors := list -}}
{{- $given := index $machine "volumes" -}}
{{- if not (kindIs "invalid" $given) -}}
{{- if not (kindIs "map" $given) -}}
{{- $errors = append $errors (printf "machines.%s.volumes: must be a map keyed by volume name, but is of type %s. The key is the name the volume's claim is derived from, so each volume is declared under its own name rather than as an item in a list." $name (kindOf $given)) -}}
{{- else -}}
{{- $inputs := splitList " " (include "stateful-pods.volume.inputs" .) -}}
{{- $reservedPaths := splitList " " (include "stateful-pods.volume.reservedPaths" .) -}}
{{- $reservedNames := splitList " " (include "stateful-pods.volume.reservedNames" .) -}}
{{- $seenPaths := dict -}}
{{- range $volumeName := keys $given | sortAlpha -}}
{{- $field := printf "machines.%s.volumes.%s" $name $volumeName -}}
{{- $entry := index $given $volumeName -}}

{{- /* The name first: it becomes a volume name in the pod specification and the
       stem of the claim, so a name the API server refuses makes the rest
       academic. */ -}}
{{- if or (gt (len $volumeName) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $volumeName)) -}}
{{- $errors = append $errors (printf "%s: %q is not a valid volume name. It must be a DNS-1123 label: at most 63 lowercase alphanumeric characters or '-', starting and ending with an alphanumeric character. The name becomes a volume in the pod and the stem of the claim behind it, and the API server refuses anything else." $field $volumeName) -}}
{{- else if has $volumeName $reservedNames -}}
{{- $errors = append $errors (printf "%s: %q is a name the chart already uses for a volume of its own in this pod. Choose another: a volume name has to be unique within the pod, and a collision is rejected by the API server. The names in use are: %s, and the machine's own object name %q." $field $volumeName (join ", " $reservedNames) $objectName) -}}
{{- else if eq $volumeName $objectName -}}
{{- $errors = append $errors (printf "%s: %q is the machine's own object name, which is what its root filesystem's volume is called. Choose another name: this one would collide with the root filesystem inside the pod." $field $volumeName) -}}
{{- end -}}

{{- if not (kindIs "map" $entry) -}}
{{- $errors = append $errors (printf "%s: must be a map of the volume's inputs, but is of type %s. Accepted inputs: %s." $field (kindOf $entry) (join ", " ($inputs | sortAlpha))) -}}
{{- else -}}
{{- range $key, $value := $entry -}}
{{- if not (has $key $inputs) -}}
{{- $errors = append $errors (printf "%s.%s: is not an input of a volume. Accepted inputs: %s." $field $key (join ", " ($inputs | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- /* Where it appears inside the machine. */ -}}
{{- $path := index $entry "mountPath" -}}
{{- if kindIs "invalid" $path -}}
{{- $errors = append $errors (printf "%s.mountPath: not set. A volume needs the path it appears at inside the machine, for example /var/lib/data." $field) -}}
{{- else if not (kindIs "string" $path) -}}
{{- $errors = append $errors (printf "%s.mountPath: must be a path, but is of type %s. A path is a string - quote it if it is one YAML reads as something else." $field (kindOf $path)) -}}
{{- else if not (hasPrefix "/" ($path | toString)) -}}
{{- $errors = append $errors (printf "%s.mountPath: %q is not an absolute path. It is where the volume appears inside the machine, so it begins at the machine's root: /var/lib/data, not var/lib/data." $field ($path | toString)) -}}
{{- else if has ".." (splitList "/" ($path | toString)) -}}
{{- $errors = append $errors (printf "%s.mountPath: %q contains \"..\". Give the path as it will be inside the machine, with no component that climbs out of it." $field ($path | toString)) -}}
{{- else if eq ($path | toString) "/" -}}
{{- $errors = append $errors (printf "%s.mountPath: \"/\" is the machine's root filesystem, which is declared at machines.%s.rootfs and seeded from machines.%s.source. A volume here would be an empty claim mounted over the operating system. Declare this volume at a path inside the machine, or change the root filesystem's own size and class under machines.%s.rootfs." $field $name $name $name) -}}
{{- else -}}
{{- $normalised := ($path | toString) | trimSuffix "/" -}}
{{- range $reserved := $reservedPaths -}}
{{- if or (eq $normalised $reserved) (hasPrefix (printf "%s/" $reserved) $normalised) -}}
{{- $errors = append $errors (printf "%s.mountPath: %q is at or under %s, which the boot sequence mounts over inside the machine after the pod's volumes are in place. A volume there would be provisioned, bound, mounted and then covered - present, empty on every start, and with nothing to say why. The machine already has a tmpfs /run and /tmp of its own; /proc, /sys and /dev are the kernel's. Choose a path the machine owns, such as /var/lib/%s." $field $normalised $reserved $volumeName) -}}
{{- end -}}
{{- end -}}
{{- $already := index $seenPaths $normalised -}}
{{- if $already -}}
{{- $errors = append $errors (printf "%s.mountPath: %q is already declared by machines.%s.volumes.%s. Two volumes cannot occupy one path: whichever the runtime mounted second would hide the other." $field $normalised $name $already) -}}
{{- else -}}
{{- $_ := set $seenPaths $normalised $volumeName -}}
{{- end -}}
{{- end -}}

{{- /* Provisioned, or somebody else's. Exactly one, and never guessed: one
       creates storage and the other consumes storage that exists. */ -}}
{{- $size := index $entry "size" -}}
{{- $claim := index $entry "existingClaim" -}}
{{- $hasSize := not (kindIs "invalid" $size) -}}
{{- $hasClaim := not (kindIs "invalid" $claim) -}}
{{- if and $hasSize $hasClaim -}}
{{- $errors = append $errors (printf "%s: names both `size` and `existingClaim`. Supply exactly one: `size` has the chart provision a claim for this machine, and `existingClaim` mounts a claim somebody else made. They are not alternatives - choosing between them here would either provision a volume nobody asked for or ignore a size you believed was in effect." $field) -}}
{{- else if not (or $hasSize $hasClaim) -}}
{{- $errors = append $errors (printf "%s: names neither `size` nor `existingClaim`. Give a size to have the chart provision a claim for this volume, or name an existing PersistentVolumeClaim in this release's namespace to mount one that is already there." $field) -}}
{{- else if $hasSize -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$" ($size | toString)) -}}
{{- $errors = append $errors (printf "%s.size: %q is not a storage quantity. Give a number with a unit, quoted or not, as the root filesystem does: 50Gi, 2Ti, 500Mi. A value the API server cannot parse renders cleanly and is refused on apply, which surfaces as a machine whose pod is never created." $field ($size | toString)) -}}
{{- end -}}
{{- $class := index $entry "storageClassName" -}}
{{- if and (not (kindIs "invalid" $class)) (not (kindIs "string" $class)) -}}
{{- $errors = append $errors (printf "%s.storageClassName: must be the name of a StorageClass, but is of type %s. Leave it out entirely to use the cluster's default class; an explicit \"\" means \"no class\" and disables dynamic provisioning, which is a different thing." $field (kindOf $class)) -}}
{{- end -}}
{{- $dataSource := index $entry "dataSource" -}}
{{- if not (kindIs "invalid" $dataSource) -}}
{{- if not (kindIs "map" $dataSource) -}}
{{- $errors = append $errors (printf "%s.dataSource: must be a map naming what the volume is restored from, but is of type %s. The one source it accepts is volumeSnapshotName." $field (kindOf $dataSource)) -}}
{{- else -}}
{{- range $key, $value := $dataSource -}}
{{- if ne $key "volumeSnapshotName" -}}
{{- $errors = append $errors (printf "%s.dataSource.%s: is not an input. Accepted inputs: volumeSnapshotName." $field $key) -}}
{{- end -}}
{{- end -}}
{{- $snapshot := index $dataSource "volumeSnapshotName" -}}
{{- if and (not (kindIs "invalid" $snapshot)) (not (kindIs "string" $snapshot)) -}}
{{- $errors = append $errors (printf "%s.dataSource.volumeSnapshotName: must be the name of a VolumeSnapshot in this release's namespace, but is of type %s." $field (kindOf $snapshot)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- if or (not (kindIs "string" $claim)) (eq ($claim | toString) "") -}}
{{- $errors = append $errors (printf "%s.existingClaim: must name a PersistentVolumeClaim in this release's namespace. The chart creates nothing for a volume declared this way, so its size, class, access mode and lifetime are the claim's own." $field) -}}
{{- else if or (gt (len ($claim | toString)) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" ($claim | toString))) -}}
{{- $errors = append $errors (printf "%s.existingClaim: %q is not a valid claim name. It must be a DNS-1123 subdomain: at most 253 lowercase alphanumeric characters, '-' or '.', with each dot-separated part starting and ending with an alphanumeric character." $field ($claim | toString)) -}}
{{- end -}}
{{- range $unused := list "size" "storageClassName" "dataSource" -}}
{{- if not (kindIs "invalid" (index $entry $unused)) -}}
{{- $errors = append $errors (printf "%s.%s: does not belong to a volume that names an existingClaim. The chart creates nothing for such a volume, so its size, class and restore source are decided by whoever made the claim. Remove the field, or remove existingClaim to have the chart provision this volume." $field $unused) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- $readOnly := index $entry "readOnly" -}}
{{- if and (not (kindIs "invalid" $readOnly)) (not (kindIs "bool" $readOnly)) -}}
{{- $errors = append $errors (printf "%s.readOnly: must be true or false, but is of type %s." $field (kindOf $readOnly)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{ toYaml $errors }}
{{- end -}}

{{/*
The checks on a machine's egress policy.

Almost all of them are about one failure: a proxy configuration Envoy refuses.
Envoy validates its configuration on startup and exits when it cannot parse or
reconcile it, which surfaces as a sidecar that crash-loops behind a machine whose
own containers are all healthy - and whose traffic, until the sidecar comes up,
is going nowhere. Two filter chains with the same match are the commonest way to
get there, so the duplicate checks below are not tidiness.

The rest are about a policy that renders, applies, and quietly means something
other than what was written: a rule whose form cannot see the thing it names, a
port the proxy already holds, a name where an address belongs.

Takes (dict "name" $name "machine" $machine). Emits a YAML list of errors,
possibly empty.
*/}}
{{- define "stateful-pods.validate.egress" -}}
{{- $name := .name -}}
{{- $machine := .machine -}}
{{- $errors := list -}}
{{- $network := index $machine "network" -}}
{{- if kindIs "map" $network -}}
{{- $egress := index $network "egress" -}}
{{- if not (kindIs "invalid" $egress) -}}
{{- if not (kindIs "map" $egress) -}}
{{- $errors = append $errors (printf "machines.%s.network.egress: must be a map, but is of type %s. Accepted inputs: %s." $name (kindOf $egress) (join ", " (splitList " " (include "stateful-pods.egress.inputs" .) | sortAlpha))) -}}
{{- else -}}
{{- $accepted := splitList " " (include "stateful-pods.egress.inputs" .) -}}
{{- $proxyPort := include "stateful-pods.egress.proxyPort" . | int64 -}}
{{- $adminPort := include "stateful-pods.egress.adminPort" . | int64 -}}
{{- range $field, $value := $egress -}}
{{- if not (has $field $accepted) -}}
{{- $errors = append $errors (printf "machines.%s.network.egress.%s: is not an input of the egress policy. Accepted inputs: %s." $name $field (join ", " ($accepted | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- /* The default first: it is what every rule is an exception to, and a policy
       whose default nobody can name is one nobody can read. */ -}}
{{- $default := index $egress "default" -}}
{{- if kindIs "invalid" $default -}}
{{- $errors = append $errors (printf "machines.%s.network.egress.default: not set. Name what happens to traffic no rule allows, explicitly: \"deny\" refuses it, \"allow\" permits it. There is no default for this, because a policy whose unmatched traffic nobody named is one that means different things to its author and its reader." $name) -}}
{{- else if or (not (kindIs "string" $default)) (not (has ($default | toString) (list "deny" "allow"))) -}}
{{- $errors = append $errors (printf "machines.%s.network.egress.default: %v is not an egress default. Accepted: \"deny\", which refuses traffic no rule allows, and \"allow\", which permits it and leaves the rules as exceptions that are only logged." $name $default) -}}
{{- end -}}

{{- $rules := index $egress "rules" -}}
{{- if not (kindIs "invalid" $rules) -}}
{{- if not (kindIs "slice" $rules) -}}
{{- $errors = append $errors (printf "machines.%s.network.egress.rules: must be a list of rules, but is of type %s. A policy is read in the order it was written, which a map would not preserve." $name (kindOf $rules)) -}}
{{- else -}}
{{- $matchers := splitList " " (include "stateful-pods.egress.matchers" .) -}}
{{- $ruleInputs := splitList " " (include "stateful-pods.egress.ruleInputs" .) -}}
{{- $httpInputs := splitList " " (include "stateful-pods.egress.httpInputs" .) -}}
{{- $seenNames := dict -}}
{{- $seenChains := dict -}}
{{- $httpPorts := dict -}}
{{- range $index, $rule := $rules -}}
{{- $field := printf "machines.%s.network.egress.rules[%d]" $name $index -}}
{{- if not (kindIs "map" $rule) -}}
{{- $errors = append $errors (printf "%s: must be a map naming what it allows, but is of type %s. Accepted inputs: %s." $field (kindOf $rule) (join ", " ($ruleInputs | sortAlpha))) -}}
{{- else -}}
{{- range $key, $value := $rule -}}
{{- if not (has $key $ruleInputs) -}}
{{- $errors = append $errors (printf "%s.%s: is not an input of an egress rule. Accepted inputs: %s." $field $key (join ", " ($ruleInputs | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- /* The name: it appears in the proxy's access log beside every connection
       the rule allowed, which is how a refusal or a permission is traced back
       to the line that caused it. */ -}}
{{- $ruleName := index $rule "name" | default "" | toString -}}
{{- if eq $ruleName "" -}}
{{- $errors = append $errors (printf "%s.name: not set. Every rule is named, because the name is what the proxy's access log puts beside each connection the rule allowed - which is how a permission is traced back to the line that granted it." $field) -}}
{{- else if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $ruleName) -}}
{{- $errors = append $errors (printf "%s.name: %q must be lowercase letters, digits and hyphens, starting and ending with a letter or a digit. It becomes part of a statistic name in the proxy." $field $ruleName) -}}
{{- else if index $seenNames $ruleName -}}
{{- $errors = append $errors (printf "%s.name: %q is already the name of another rule. Two rules of one name make the access log unreadable, which is the only place a policy explains itself." $field $ruleName) -}}
{{- else -}}
{{- $_ := set $seenNames $ruleName true -}}
{{- end -}}

{{- /* Exactly one matcher. A rule matching on two layers at once would be a
       rule whose refusals nobody could predict. */ -}}
{{- $named := list -}}
{{- range $matcher := $matchers -}}
{{- if not (kindIs "invalid" (index $rule $matcher)) -}}
{{- $named = append $named $matcher -}}
{{- end -}}
{{- end -}}
{{- if gt (len $named) 1 -}}
{{- $errors = append $errors (printf "%s: names %s. A rule matches on exactly one of them: %s. They see different things - an address, the name in a TLS handshake, a plaintext request - and a rule combining two would be one whose refusals nobody could predict. Write two rules." $field (join " and " $named) (join ", " ($matchers | sortAlpha))) -}}
{{- else if eq (len $named) 0 -}}
{{- $errors = append $errors (printf "%s: names nothing to match on. Give exactly one of: %s. `cidrs` matches the connection's destination, `serverNames` the name the machine asks for in the TLS handshake, and `http` the authority and path of a plaintext request." $field (join ", " ($matchers | sortAlpha))) -}}
{{- end -}}

{{- $protocol := index $rule "protocol" | default "TCP" | toString -}}
{{- if not (has $protocol (list "TCP" "UDP")) -}}
{{- $errors = append $errors (printf "%s.protocol: %q is not a protocol a rule may name. Accepted: TCP, which the proxy decides, and UDP, which the packet filter decides and which therefore takes only `cidrs`." $field $protocol) -}}
{{- else if and (eq $protocol "UDP") (eq (len $named) 1) (ne (index $named 0) "cidrs") -}}
{{- $errors = append $errors (printf "%s: is a UDP rule matching on %q, which only a proxy could see, and UDP is not proxied here. A UDP rule matches on `cidrs` and `ports`. Everything above layer 4 on a UDP flow is invisible to this chart, and pretending otherwise would be a rule that never matches." $field (index $named 0)) -}}
{{- end -}}

{{- /* The ports. */ -}}
{{- $ports := index $rule "ports" -}}
{{- $portsUsable := true -}}
{{- if kindIs "invalid" $ports -}}
{{- $errors = append $errors (printf "%s.ports: not set. A rule names the ports it allows, as a list of numbers: a rule with no port would allow its destination on every port, which is almost never what anyone means and is never what anyone should have to guess." $field) -}}
{{- $portsUsable = false -}}
{{- else if or (not (kindIs "slice" $ports)) (eq (len $ports) 0) -}}
{{- $errors = append $errors (printf "%s.ports: must be a non-empty list of port numbers." $field) -}}
{{- $portsUsable = false -}}
{{- else -}}
{{- range $port := $ports -}}
{{- if or (kindIs "string" $port) (not (regexMatch "^[0-9]+$" ($port | toString))) (lt ($port | int64) 1) (gt ($port | int64) 65535) -}}
{{- $errors = append $errors (printf "%s.ports: %v is not a port number. Each must be a whole number between 1 and 65535, unquoted." $field $port) -}}
{{- $portsUsable = false -}}
{{- else if or (eq ($port | int64) $proxyPort) (eq ($port | int64) $adminPort) -}}
{{- $errors = append $errors (printf "%s.ports: %v is a port the proxy itself holds inside this pod (%d for the traffic it decides, %d for its administration). A rule naming it would describe traffic that never reaches the network." $field $port $proxyPort $adminPort) -}}
{{- $portsUsable = false -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Each matcher's own shape, and the chain it would render. */ -}}
{{- if eq (len $named) 1 -}}
{{- $matcher := index $named 0 -}}
{{- if eq $matcher "serverNames" -}}
{{- $serverNames := index $rule "serverNames" -}}
{{- if or (not (kindIs "slice" $serverNames)) (eq (len $serverNames) 0) -}}
{{- $errors = append $errors (printf "%s.serverNames: must be a non-empty list of host names." $field) -}}
{{- else -}}
{{- range $serverName := $serverNames -}}
{{- if or (not (kindIs "string" $serverName)) (not (regexMatch "^(\\*\\.)?[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)*$" ($serverName | toString))) -}}
{{- $errors = append $errors (printf "%s.serverNames: %v is not a host name. It is matched against the name the machine puts in its TLS handshake, so it is a name and never an address or a URL; a leading \"*.\" matches one level of subdomain." $field $serverName) -}}
{{- else if $portsUsable -}}
{{- range $port := $ports -}}
{{- $chain := printf "sni/%d/%s" ($port | int64) ($serverName | toString) -}}
{{- if index $seenChains $chain -}}
{{- $errors = append $errors (printf "%s: allows %s on port %v, which %s already allows. Two rules producing the same match render two identical filter chains, which the proxy refuses outright - so the machine would start and its sidecar would crash-loop behind it." $field $serverName $port (index $seenChains $chain)) -}}
{{- else -}}
{{- $_ := set $seenChains $chain $field -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else if eq $matcher "cidrs" -}}
{{- $cidrs := index $rule "cidrs" -}}
{{- if or (not (kindIs "slice" $cidrs)) (eq (len $cidrs) 0) -}}
{{- $errors = append $errors (printf "%s.cidrs: must be a non-empty list of address ranges, each as an address and a prefix length: 10.0.5.7/32, 10.96.0.0/12." $field) -}}
{{- else -}}
{{- range $cidr := $cidrs -}}
{{- if or (not (kindIs "string" $cidr)) (not (regexMatch "^([0-9]{1,3}\\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$" ($cidr | toString))) -}}
{{- $errors = append $errors (printf "%s.cidrs: %v is not an IPv4 address range. Give an address and a prefix length, for example 10.0.5.7/32. IPv6 is not proxied here - under a default of deny it is dropped, and under allow it is untouched - so an IPv6 range would be a rule that never matched." $field $cidr) -}}
{{- else if $portsUsable -}}
{{- range $port := $ports -}}
{{- $chain := printf "cidr/%d/%s" ($port | int64) ($cidr | toString) -}}
{{- if index $seenChains $chain -}}
{{- $errors = append $errors (printf "%s: allows %s on port %v, which %s already allows. Two rules producing the same match render two identical filter chains, which the proxy refuses outright." $field $cidr $port (index $seenChains $chain)) -}}
{{- else -}}
{{- $_ := set $seenChains $chain $field -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- else if eq $matcher "http" -}}
{{- $http := index $rule "http" -}}
{{- if not (kindIs "map" $http) -}}
{{- $errors = append $errors (printf "%s.http: must be a map naming the authority and, optionally, a path prefix. Accepted inputs: %s." $field (join ", " ($httpInputs | sortAlpha))) -}}
{{- else -}}
{{- range $key, $value := $http -}}
{{- if not (has $key $httpInputs) -}}
{{- $errors = append $errors (printf "%s.http.%s: is not an input. Accepted inputs: %s. A method or a header matcher is not offered: this rule sees a plaintext request, and the useful half of what it can see is where the request is going." $field $key (join ", " ($httpInputs | sortAlpha))) -}}
{{- end -}}
{{- end -}}
{{- $authority := index $http "authority" | default "" | toString -}}
{{- if eq $authority "" -}}
{{- $errors = append $errors (printf "%s.http.authority: not set. An http rule matches the host a plaintext request is addressed to, so it needs one." $field) -}}
{{- else if not (regexMatch "^[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([-a-zA-Z0-9]*[a-zA-Z0-9])?)*$" $authority) -}}
{{- $errors = append $errors (printf "%s.http.authority: %q is not a host name. Give the host alone, without a scheme, a port or a path - the port is in `ports` and the path in `pathPrefix`." $field $authority) -}}
{{- end -}}
{{- $prefix := index $http "pathPrefix" -}}
{{- if and (not (kindIs "invalid" $prefix)) (or (not (kindIs "string" $prefix)) (not (hasPrefix "/" ($prefix | toString)))) -}}
{{- $errors = append $errors (printf "%s.http.pathPrefix: %v is not a path. It begins at the root of the request: /debian/, not debian/. Leave it out to allow every path on that authority." $field $prefix) -}}
{{- end -}}
{{- if $portsUsable -}}
{{- range $port := $ports -}}
{{- $chain := printf "http/%d/%s%s" ($port | int64) $authority ($prefix | default "/" | toString) -}}
{{- if index $seenChains $chain -}}
{{- $errors = append $errors (printf "%s: allows the same authority and path prefix on port %v as %s. One of them has no effect, and which one is not something a reader should have to work out from the order." $field $port (index $seenChains $chain)) -}}
{{- else -}}
{{- $_ := set $seenChains $chain $field -}}
{{- end -}}
{{- $_ := set $httpPorts (printf "%d" ($port | int64)) $field -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* A machine cannot serve a port the proxy is holding in the same
       namespace, and the two blocks are far enough apart in a values file
       that nobody would notice. */ -}}
{{- range $port := include "stateful-pods.machine.ports" (dict "root" $.root "name" $name "machine" $machine) | fromYamlArray -}}
{{- if or (eq (int64 $port.port) $proxyPort) (eq (int64 $port.port) $adminPort) -}}
{{- $errors = append $errors (printf "machines.%s.network.ports.%s: %d is a port the egress proxy holds inside this machine's pod. Nothing outside would reach the machine on it, because the proxy answers there first. Serve this on another port, or remove machines.%s.network.egress." $name $port.name (int64 $port.port) $name) -}}
{{- end -}}
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
{{- /* Checked only when a machine asks for it. A release whose machines declare
       no egress policy renders no proxy and must not be refused for the sake of
       an image it will never pull. */ -}}
{{- $wantsProxy := false -}}
{{- range $name, $machine := $root.Values.machines -}}
{{- if and (kindIs "map" $machine) (kindIs "map" (index $machine "network")) -}}
{{- if kindIs "map" (index (index $machine "network") "egress") -}}
{{- $wantsProxy = true -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $wantsProxy -}}
{{- $envoy := $root.Values.envoy | default dict -}}
{{- if or (not (kindIs "map" $envoy)) (eq ($envoy.image | default "") "") -}}
{{- $errors = append $errors "envoy.image: not set, and a machine in this release declares an egress policy. It is the image of the proxy that decides what such a machine may reach, and it is the one image this chart runs that it did not build. Leave the chart default in place unless you are pinning your own build of Envoy." -}}
{{- end -}}
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
{{- $errors = concat $errors (include "stateful-pods.validate.provisioning" (dict "objectName" $objectName "name" $name "machine" $machine) | fromYamlArray) -}}

{{- /* What the cluster is told about the machine's network presence. */ -}}
{{- $errors = concat $errors (include "stateful-pods.validate.network" (dict "name" $name "machine" $machine) | fromYamlArray) -}}

{{- /* The storage the machine has beside its root filesystem. */ -}}
{{- $errors = concat $errors (include "stateful-pods.validate.volumes" (dict "objectName" $objectName "name" $name "machine" $machine) | fromYamlArray) -}}

{{- /* What the machine may reach, and what happens to everything else. */ -}}
{{- $errors = concat $errors (include "stateful-pods.validate.egress" (dict "root" $root "name" $name "machine" $machine) | fromYamlArray) -}}

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

{{/*
The ingress postures a machine may ask for. It doubles as the documentation of
them, which is why it states what each one renders and what enforcing it depends
on.
*/}}
{{- define "stateful-pods.errors.ingressPostures" }}
      any      - the cluster is told nothing about which ports may be reached, and the machine is
                 reachable on every port something inside it listens on. The default, and what a
                 machine gets when it names no posture: a chart upgrade must not take a running
                 pet off the network.
      declared - a NetworkPolicy admitting inbound traffic to the ports declared under
                 machines.<name>.network.ports and to no others. Outbound traffic is untouched.
                 A NetworkPolicy is enforced by the cluster's network plugin and by nothing else,
                 so on a cluster whose plugin implements none this posture is accepted by the API
                 server and restricts nothing at all.
{{- end -}}
