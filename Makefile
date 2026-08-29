CHART ?= charts/stateful-pods
IMAGE ?= stateful-pods-shim:dev
IMAGE_CONTEXT ?= images/shim
EXAMPLES ?= $(wildcard $(CHART)/examples/*.yaml)
HELM ?= helm
KUBECONFORM ?= kubeconform
KUBE_VERSION ?= 1.33.0

.PHONY: all lint shell-lint test shell-test render conform docs image-build image-test integration-test

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

## shell-test: run the bats suites for the chart's shell scripts
shell-test:
	./hack/shell-test.sh

## image-build: build the toolbox image for the host architecture
image-build:
	docker build --tag $(IMAGE) --file $(IMAGE_CONTEXT)/Containerfile $(IMAGE_CONTEXT)

## image-test: assert the toolbox image's archive guarantees against a busybox control
image-test: image-build
	IMAGE=$(IMAGE) ./hack/image-test.sh

## integration-test: seed a machine end to end on a throwaway kind cluster
integration-test:
	./hack/integration-test.sh

## render: render the chart from the first example to stdout
render:
	$(HELM) template stateful-pods $(CHART) --values $(firstword $(EXAMPLES)) --kube-version $(KUBE_VERSION)

## conform: validate every example's rendered manifest against the Kubernetes API schemas
conform:
	@for values in $(EXAMPLES); do \
		echo "==> kubeconform $$values"; \
		$(HELM) template stateful-pods $(CHART) --values $$values --kube-version $(KUBE_VERSION) \
			| $(KUBECONFORM) -strict -summary -kubernetes-version $(KUBE_VERSION) || exit 1; \
	done
