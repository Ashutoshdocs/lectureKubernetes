# Usage:  make build ENV=dev | make diff ENV=prod | make apply ENV=staging
ENV ?= dev
K   ?= kubectl
DIR := overlays/$(ENV)
NS  := student-$(ENV)

.PHONY: help secrets build build-all diff apply status open delete delete-all validate

help:          ## Show targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

secrets:       ## Create prod secrets.env from the example (first run only)
	@test -f overlays/prod/secrets.env || cp overlays/prod/secrets.env.example overlays/prod/secrets.env

build: secrets ## Render one environment to stdout
	$(K) kustomize $(DIR)

build-all: secrets ## Render every environment into rendered/<env>.yaml
	@mkdir -p rendered
	@$(K) kustomize base > rendered/base.yaml
	@for e in dev staging prod; do $(K) kustomize overlays/$$e > rendered/$$e.yaml; echo "rendered/$$e.yaml"; done

diff: secrets  ## Show what would change in the cluster
	-$(K) diff -k $(DIR)

apply: secrets ## Deploy one environment
	$(K) apply -k $(DIR)
	$(K) -n $(NS) rollout status deploy -l app=student --timeout=90s

status:        ## Show everything in the environment's namespace
	$(K) -n $(NS) get all,cm,secret,hpa,pdb --show-labels

open:          ## Port-forward the service to http://localhost:8080
	$(K) -n $(NS) port-forward svc/$$($(K) -n $(NS) get svc -l app.kubernetes.io/name=student-app -o name | cut -d/ -f2) 8080:80

delete:        ## Remove one environment (including its namespace)
	$(K) delete -k $(DIR) --ignore-not-found

delete-all:    ## Remove every environment
	-@for e in dev staging prod; do $(K) delete -k overlays/$$e --ignore-not-found; done

validate: secrets ## Build all + schema-check (uses kubeconform if installed)
	./scripts/validate.sh
