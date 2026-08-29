CHART ?= charts/stateful-pods
EXAMPLES ?= $(wildcard $(CHART)/examples/*.yaml)
HELM ?= helm
KUBECONFORM ?= kubeconform
KUBE_VERSION ?= 1.33.0

.PHONY: all lint test render conform docs

all: lint docs test conform

## lint: run helm lint in strict mode against every example
#  The chart's default values declare no machine on purpose, so linting has to be
#  given a machine to render.
lint:
	@for values in $(EXAMPLES); do \
		echo "==> helm lint --strict $(CHART) --values $$values"; \
		$(HELM) lint --strict $(CHART) --values $$values --kube-version $(KUBE_VERSION) || exit 1; \
	done

## docs: check the documentation guarantees values.yaml makes
docs:
	./hack/check-values-docs.sh $(CHART)/values.yaml

## test: run the helm unittest suites
test:
	$(HELM) unittest $(CHART)

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
