# Falco Kubernetes demo — convenience targets.
# Run `make help` for the list.

NS        ?= falco
RELEASE   ?= falco
CHART     ?= falcosecurity/falco
VALUES    ?= install/values.yaml
DEMO_NS   ?= demo-apps

.DEFAULT_GOAL := help

.PHONY: help repo install status logs sidekick-logs ui deploy-demo demo rules clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

repo: ## Add/update the Falco Helm repo
	helm repo add falcosecurity https://falcosecurity.github.io/charts
	helm repo update

install: repo ## Install Falco + Falcosidekick with our values, then deploy demo app
	helm upgrade --install $(RELEASE) $(CHART) \
	  --namespace $(NS) --create-namespace \
	  -f $(VALUES)
	@$(MAKE) --no-print-directory deploy-demo

status: ## Show Falco pods / daemonset status
	kubectl -n $(NS) get pods,daemonset -o wide

logs: ## Stream Falco alerts (Ctrl-C to stop)
	kubectl -n $(NS) logs -l app.kubernetes.io/name=falco -c falco -f

sidekick-logs: ## Stream Falcosidekick logs (alert routing)
	kubectl -n $(NS) logs deploy/$(RELEASE)-falcosidekick -f

ui: ## Port-forward the Falcosidekick web UI to http://localhost:2802
	@echo "Falcosidekick UI → http://localhost:2802 (default admin/admin)"
	kubectl -n $(NS) port-forward svc/$(RELEASE)-falcosidekick-ui 2802:2802

deploy-demo: ## Create the demo namespace + victim workload
	kubectl apply -f demo/00-demo-namespace.yaml
	kubectl -n $(DEMO_NS) rollout status deploy/victim --timeout=90s

demo: ## Run all attack-simulation scenarios (interactive)
	./demo/run-all.sh

rules: ## Reload custom rules after editing install/values.yaml
	helm upgrade $(RELEASE) $(CHART) -n $(NS) -f $(VALUES)

clean: ## Uninstall everything created by this demo
	-kubectl delete -f demo/05-crypto-miner-sim.yaml --ignore-not-found
	-kubectl delete -f demo/00-demo-namespace.yaml --ignore-not-found
	-helm uninstall $(RELEASE) -n $(NS)
	-kubectl delete ns $(NS) $(DEMO_NS) --ignore-not-found
