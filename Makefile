CHART ?= charts/stateful-pods
IMAGE ?= stateful-pods-shim:dev
IMAGE_CONTEXT ?= images/shim
EXAMPLES ?= $(wildcard $(CHART)/examples/*.yaml)
RENDER_EXAMPLE ?= $(CHART)/examples/oci.yaml
HELM ?= helm
BATS ?= bats
# The bash the plugin's suite runs the plugin under. Empty means the one its
# shebang finds; a path is how the macOS job pins it to the system bash 3.2.
MACHINE_BASH ?=
# Guarded against expanding to nothing below, because a suite list that came out
# empty is a target that passes having run no tests.
PLUGIN_SUITES_GLOB ?= test/shell/plugin-*.bats
PLUGIN_SUITES ?= $(wildcard $(PLUGIN_SUITES_GLOB))
KUBECONFORM ?= kubeconform
KUBE_VERSION ?= 1.33.0
# The chart's own floor, read out of Chart.yaml rather than repeated here: a
# floor raised there would otherwise leave this validating the version it used
# to be, and the check would go on passing while proving the wrong thing.
#
# It is checked at all because a field the oldest supported API does not have is
# a chart that installs on that cluster and behaves differently there - which is
# what the guest's access-control profile would have been below 1.30. Validating
# only at the version above would not have seen it.
#
# The privileged example, because that is the mode the floor is about: `userns`
# needs 1.33 and the chart refuses it below that, so a userns example cannot
# render at the floor at all.
KUBE_VERSION_FLOOR ?= $(shell sed -n 's/^kubeVersion: ">= \(.*\)-0"$$/\1/p' $(CHART)/Chart.yaml)
FLOOR_EXAMPLE ?= $(CHART)/examples/lxc.yaml

.PHONY: all lint shell-lint test shell-test plugin-test render conform docs presets image-build image-test integration-test seccomp-test preset-test preset-build

all: lint shell-lint docs presets test shell-test preset-test conform

## lint: run helm lint in strict mode against every example
#  The chart's default values declare no machine on purpose, so linting has to be
#  given a machine to render.
lint:
	@for values in $(EXAMPLES); do \
		echo "==> helm lint --strict $(CHART) --values $$values"; \
		$(HELM) lint --strict $(CHART) --values $$values --kube-version $(KUBE_VERSION) || exit 1; \
	done

## shell-lint: run shellcheck over every shell script
shell-lint:
	./hack/shell-lint.sh

## docs: check the documentation guarantees values.yaml makes
docs:
	./hack/check-values-docs.sh $(CHART)/values.yaml

## presets: check the catalog the chart ships against what the project builds
presets:
	./hack/check-presets.sh $(CHART)/presets.yaml images/presets/presets.list

## test: run the helm unittest suites
test:
	$(HELM) unittest $(CHART)

## shell-test: run the bats suites for the shim image's shell scripts
shell-test:
	./hack/shell-test.sh

## plugin-test: run the kubectl plugin's suite against a bash on this host
#  The one part of test/shell that is not about another system's root
#  filesystem: these suites stub kubectl and helm and assert what the plugin
#  composes, so they need neither Linux nor a container. `make shell-test` runs
#  them too, in the container, against whatever bash Debian ships.
#
#  This target exists for the bash that is not that one. The plugin targets bash
#  3.2 because that is what macOS ships, and every construct that breaks the
#  target - mapfile, an associative array, ${var^^} - breaks at runtime on
#  somebody's Mac rather than in a suite on Linux:
#
#    make plugin-test MACHINE_BASH=/bin/bash
#
#  It needs bats on the host, which nothing else here does.
plugin-test:
	@test -n "$(PLUGIN_SUITES)" || { echo "no plugin suites matched $(PLUGIN_SUITES_GLOB)" >&2; exit 1; }
	MACHINE_BASH=$(MACHINE_BASH) $(BATS) $(PLUGIN_SUITES)

## preset-test: assert what the preset build refuses
#  In `all`, and not in `image-test` or `integration-test`, because it needs
#  neither a registry nor a cluster: it runs against a mirror on the local
#  filesystem. What it covers is the reason a preset is worth more than an `lxc`
#  source - that the upstream's signature was checked against the key this
#  repository pins - and that guarantee is only worth as much as the failures
#  around it, so they are checked on every run rather than on the ones that
#  happen to have a registry.
preset-test:
	./hack/preset-test.sh

## preset-build: verify and publish the preset images
#  Publishing, not building: there is nothing to build. The verified upstream
#  archive becomes the image's single layer, so this needs a registry to push to
#  rather than a builder to run.
#
#  Takes arguments through PRESET_ARGS, because what it does depends entirely on
#  them - `PRESET_ARGS=--resolve-only` reports what the upstream offers and
#  touches nothing, and naming presets builds only those:
#
#    make preset-build PRESET_ARGS="--resolve-only"
#    make preset-build PRESET_ARGS="--repository localhost:5000/preset- alpine-3.24"
preset-build:
	./hack/preset-build.sh $(PRESET_ARGS)

## image-build: build the toolbox image for the host architecture
image-build:
	docker build --tag $(IMAGE) --file $(IMAGE_CONTEXT)/Containerfile $(IMAGE_CONTEXT)

## image-test: assert the toolbox image's archive and registry guarantees
image-test: image-build
	IMAGE=$(IMAGE) ./hack/image-test.sh

## integration-test: assert the syscall filter on a kind cluster whose kubelet
#  filters by default, then seed a machine end to end on a second one
#
#  The syscall suite runs first, and the order is not arbitrary. Its assertions
#  are pairs: each call the profile denies is also made with no profile at all,
#  so that "the profile denies it" cannot pass because the call was refused for
#  some other reason. Those control halves need the host kernel in the state it
#  booted in.
#
#  A machine in `privileged` mode can take it out of that state. Void's root
#  filesystem ships kernel.kexec_load_disabled=1 in /usr/lib/sysctl.d, its init
#  applies it, and that particular switch only goes one way - so once a Void
#  machine has booted, kexec_load is refused for everything else on that host,
#  including the second cluster. Every kind node shares the host's kernel.
#
#  This is what `privileged` means, working as documented rather than failing.
#  The suites are ordered rather than the guest constrained, because constraining
#  it would make the test prove something about a machine nobody runs.
integration-test:
	./hack/seccomp-test.sh
	./hack/integration-test.sh

## seccomp-test: the syscall filter assertions alone, on their own kind cluster
seccomp-test:
	./hack/seccomp-test.sh

## render: render the chart from the oci example to stdout
#  Named rather than taken from the wildcard: the example that sorts first is not
#  a decision anyone made, and one naming a profile file that has to be placed on
#  a node is a strange thing to hand someone as the canonical render.
render:
	$(HELM) template stateful-pods $(CHART) --values $(RENDER_EXAMPLE) --kube-version $(KUBE_VERSION)

## conform: validate every example's rendered manifest against the Kubernetes API
#  schemas, at the version this chart is developed against and at its own floor
conform:
	@for values in $(EXAMPLES); do \
		echo "==> kubeconform $$values (Kubernetes $(KUBE_VERSION))"; \
		$(HELM) template stateful-pods $(CHART) --values $$values --kube-version $(KUBE_VERSION) \
			| $(KUBECONFORM) -strict -summary -kubernetes-version $(KUBE_VERSION) || exit 1; \
	done
	@echo "==> kubeconform $(FLOOR_EXAMPLE) (Kubernetes $(KUBE_VERSION_FLOOR), the chart's floor)"
	@#  Rendered on its own first. In a pipeline the exit status is kubeconform's,
	@#  and kubeconform is perfectly happy with the empty input a failed render
	@#  gives it - it reports no resources and succeeds, so a chart that could not
	@#  render at its own floor would pass this silently.
	@$(HELM) template stateful-pods $(CHART) --values $(FLOOR_EXAMPLE) \
		--kube-version $(KUBE_VERSION_FLOOR) > /dev/null
	@$(HELM) template stateful-pods $(CHART) --values $(FLOOR_EXAMPLE) \
		--kube-version $(KUBE_VERSION_FLOOR) \
		| $(KUBECONFORM) -strict -summary -kubernetes-version $(KUBE_VERSION_FLOOR)
