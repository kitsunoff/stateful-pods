## Context

`stateful-pods.validate.structure` refuses a machines map holding more than one entry. Everything
else in the chart was written as though the refusal were not there: helpers take
`(dict "root" $ "name" $name "machine" $machine)` and read no `.Values.machines` of their own,
because a helper that reached for the only entry would be correct today and silently wrong the
moment a release had two.

## Goals

- A release holds as many machines as its values declare, and each gets exactly what it declared.
- Nothing a machine has is shared with a machine beside it, except the release's lifetime.
- The two commands that act on a release rather than on a machine stop being able to surprise
  somebody.

## Non-goals

See the proposal.

## Decisions

### The chart needed nothing but the refusal removed, and that was checked rather than assumed

Rendering a release with two machines, each declaring a volume, ports, an ingress posture, an egress
policy and a script, produces eighteen objects:

```text
StatefulSet     lab-web              lab-db
Service         lab-web              lab-db
NetworkPolicy   lab-web              lab-db
ConfigMap       lab-web-egress       (db declared no policy)
Secret          lab-web-provisioning lab-db-provisioning
ServiceAccount  lab-web-exec         lab-db-exec
Role            lab-web-exec         lab-db-exec
RoleBinding     lab-web-exec         lab-db-exec
Job             lab-web-exec-<8>     lab-db-exec-<8>
```

Every name is distinct, and `kubeconform` accepts the lot. The one place two machines meet is the
volume claim template a declared volume renders, which is named for the **volume** — so both
machines have a template called `data`, in different StatefulSets, and the controller appends the
pod's name to each: `data-lab-web-0` and `data-lab-db-0`. That naming was chosen for a length
budget; it turns out to be what makes two machines able to share a volume name without sharing a
volume, and the suite now asserts it.

### The cost is in the plugin, and it is in the two commands that act on a release

`shell`, `console`, `status` and `list` address a machine and are unaffected. Two are not:

**`delete`** runs `helm uninstall`. Its output has always said "This removes the release", which was
a complete description while a release held one machine. It now reads the release's other machines
and names them, and asks for the release's name to confirm.

Asking for the release's name rather than the machine's is the part worth arguing for. The
confirmation exists to make an irreversible-feeling act deliberate, and typing `web` to stop `db` is
a confirmation that confirms the wrong thing — the user has answered a question about a machine and
been charged for a release. Typing `lab` is answering the question actually being asked.

**`create`** runs `helm upgrade --install` with one machine's `--set` values. Helm replaces a
release's values with what it is given, so a release holding `db` would come back holding only
`web`, and `db`'s StatefulSet, Service and policy would be deleted. Its volume would survive, which
makes it recoverable and not less alarming.

It refuses. The alternative is `--reuse-values`, and that flag does more than merge: it pins the
release to the values it already has, so the chart's own new defaults stop reaching it on upgrade.
Choosing that for a machine the user did not mention is exactly the kind of decision this plugin
does not make — `create` has never validated an input, on the grounds that there should be one
explanation of a value and it should be the chart's.

### What the refusal is replaced with in the specs

`values-validation` carried *Exactly one machine per release, for now*, whose second scenario
required the refusal. The requirement is removed rather than rewritten: what remains true of an
empty map is already required by the scenario above it, and there is nothing left to refuse.

`machine-topology` gains the property that made all of this possible and that a future change could
break without noticing — machines in one release share no object, and a change to one does not
replace another.
