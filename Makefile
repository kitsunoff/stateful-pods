CHART ?= charts/stateful-pods
IMAGE ?= stateful-pods-shim:dev
IMAGE_CONTEXT ?= images/shim
EXAMPLES ?= $(wildcard $(CHART)/examples/*.yaml)
RENDER_EXAMPLE ?= $(CHART)/examples/oci.yaml
HELM ?= helm
KUBECONFORM ?= kubeconform
KUBE_VERSION ?= 1.33.0
# The chart's own floor, and the one example that renders there. It duplicates
# Chart.yaml's kubeVersion by hand - nothing ties the two together, so a floor
# raised there has to be raised here as well or this validates the wrong version. A field the oldest supported API does not have is a chart that
# installs on that cluster and behaves differently - which is what the guest's
# access-control profile would have been below 1.30, and validating only at the
# version above would not have seen it.
#
# The privileged example, because that is the mode the floor is about: `userns`
# needs 1.33 and the chart refuses it below that, so a userns example cannot
# render at the floor at all.
KUBE_VERSION_FLOOR ?= 1.30.0
FLOOR_EXAMPLE ?= $(CHART)/examples/lxc.yaml

.PHONY: all lint shell-lint test shell-test render conform docs image-build image-test integration-test seccomp-test

all: lint shell-lint docs test shell-test conform

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
