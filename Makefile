# helm-charts - Helm Charts Repo

## Project Variables

PROJECT_NAME  := helm-charts
PROJECT_OWNER := donaldgifford
DESCRIPTION   := Helm Charts Repo
PROJECT_URL   := https://github.com/$(PROJECT_OWNER)/$(PROJECT_NAME)

## Version Information

COMMIT_HASH ?= $(shell git rev-parse --short HEAD 2>/dev/null)
VERSION     ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

## Helm Variables

CHART_DIR := charts
CHARTS    := $(wildcard $(CHART_DIR)/*/Chart.yaml)


###############
##@ Helm

.PHONY: helm-lint helm-template helm-template-ci helm-package
.PHONY: helm-unittest helm-test helm-ct-lint helm-ct-list-changed helm-ct-install
.PHONY: helm-docs helm-docs-check helm-diff-check helm-cr-package

helm-lint: ## Lint all charts
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else helm lint $(CHART_DIR)/*; fi

helm-template: ## Render Helm templates with default values
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else for chart in $(CHART_DIR)/*/; do \
		echo "--- $${chart} ---"; \
		helm template $$(basename $${chart}) $${chart}; \
	done; fi

helm-template-ci: ## Render Helm templates with CI values
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else for chart in $(CHART_DIR)/*/; do \
		for vals in $${chart}ci/*.yaml; do \
			[ -f "$${vals}" ] || continue; \
			echo "--- $${chart} ($${vals}) ---"; \
			helm template $$(basename $${chart}) $${chart} -f $${vals}; \
		done; \
	done; fi

helm-package: ## Package all charts to .tgz
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else for chart in $(CHART_DIR)/*/; do \
		helm package $${chart}; \
	done; fi

helm-unittest: ## Run helm-unittest plugin tests
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else helm unittest $(CHART_DIR)/*; fi

helm-test: helm-lint helm-unittest ## Run Helm lint + unit tests

helm-ct-lint: ## Run chart-testing lint
	@ $(MAKE) --no-print-directory log-$@
	@ct lint --config ct.yaml --all

helm-ct-list-changed: ## List charts changed since target branch
	@ $(MAKE) --no-print-directory log-$@
	@ct list-changed --config ct.yaml

helm-ct-install: ## Install and test charts in kind cluster
	@ $(MAKE) --no-print-directory log-$@
	@ct install --config ct.yaml

helm-docs: ## Generate chart READMEs with helm-docs
	@ $(MAKE) --no-print-directory log-$@
	@helm-docs --chart-search-root $(CHART_DIR)

helm-docs-check: ## Check that helm-docs are up to date
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else helm-docs --chart-search-root $(CHART_DIR) && \
		if ! git diff --quiet; then \
			echo "helm-docs are out of date — run 'make helm-docs'" && exit 1; \
		fi; \
	fi

helm-diff-check: ## Show diff between installed release and local chart (RELEASE= CHART=)
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(RELEASE)" ] || [ -z "$(CHART)" ]; then \
		echo "Usage: make helm-diff-check RELEASE=fleetdm CHART=charts/fleetdm"; \
		exit 1; \
	fi
	@helm diff upgrade $(RELEASE) $(CHART)

helm-cr-package: ## Package charts with chart-releaser
	@ $(MAKE) --no-print-directory log-$@
	@if [ -z "$(CHARTS)" ]; then echo "No charts found, skipping"; \
	else for chart in $(CHART_DIR)/*/; do \
		cr package $${chart}; \
	done; fi

##@ CI

.PHONY: ci check clean

ci: helm-lint helm-unittest helm-ct-lint ## Run CI pipeline (lint + unittest + ct lint)
	@ $(MAKE) --no-print-directory log-$@
	@echo "✓ CI pipeline complete"

check: helm-lint helm-unittest ## Quick pre-commit check (lint + unittest)
	@ $(MAKE) --no-print-directory log-$@
	@echo "✓ Pre-commit checks passed"

clean: ## Remove packaged chart artifacts
	@ $(MAKE) --no-print-directory log-$@
	@rm -f *.tgz
	@rm -rf .cr-release-packages/
	@echo "✓ Build artifacts cleaned"


########################################################################
## Self-Documenting Makefile Help                                     ##
## https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html ##
########################################################################

########
##@ Help

.PHONY: help
help:   ## Display this help
	@awk -v "col=\033[36m" -v "nocol=\033[0m" ' \
		BEGIN { FS = ":.*##" ; printf "Usage:\n  make %s<target>%s\n\n", col, nocol } \
		/^[a-zA-Z_0-9-]+:.*?##/ { printf "  %s%-25s%s %s\n", col, $$1, nocol, $$2 } \
		/^##@/ { printf "\n%s%s%s\n", nocol, substr($$0, 5), nocol } \
	' $(MAKEFILE_LIST)

## Log Pattern
## Automatically logs what a target does by extracting its ## comment
log-%:
	@grep -h -E '^$*:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN { FS = ":.*?## " }; { printf "\033[36m==> %s\033[0m\n", $$2 }'
