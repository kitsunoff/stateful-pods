CHART ?= charts/stateful-pods
IMAGE ?= stateful-pods-shim:dev
IMAGE_CONTEXT ?= images/shim
EXAMPLES ?= $(wildcard $(CHART)/examples/*.yaml)
RENDER_EXAMPLE ?= $(CHART)/examples/oci.yaml
HELM ?= helm
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

.PHONY: all lint shell-lint test shell-test render conform docs image-build image-test integration-test seccomp-test preset-test preset-build

all: lint shell-lint docs test shell-test preset-test conform

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

## test: run the helm unittest suites
test:
	$(HELM) unittest $(CHART)

## shell-test: run the bats suites for the shim image's shell scripts
shell-test:
	./hack/shell-test.sh

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

## integration-test: seed a machine end to end on a throwaway kind cluster, then
#  assert the syscall filter on a second one whose kubelet filters by default
integration-test:
	./hack/integration-test.sh
	./hack/seccomp-test.sh

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
