# HPA demo — common tasks. Run `make help` to see everything.
METRICS_VERSION ?= v0.8.1

.PHONY: help setup deploy load watch top status clean destroy

help:
	@echo "HPA demo targets:"
	@echo "  make setup    - install + configure metrics-server"
	@echo "  make deploy   - apply Deployment, Service, and HPA"
	@echo "  make load     - start the load-generator pod"
	@echo "  make watch    - live view of the HPA and pods scaling"
	@echo "  make top      - current CPU/memory usage of the nginx pods"
	@echo "  make status   - one-shot snapshot of all demo objects"
	@echo "  make clean    - stop the load generator only"
	@echo "  make destroy  - delete all demo resources"

setup:
	./setup.sh

deploy:
	kubectl apply -f deployment.yaml
	kubectl apply -f service.yaml
	kubectl apply -f hpa.yaml

load:
	kubectl apply -f generator.yaml

watch:
	watch -n 2 'kubectl get hpa nginx-hpa; echo; kubectl get pods -l app=nginx-hpa'

top:
	kubectl top pods -l app=nginx-hpa

status:
	kubectl get deployment,svc,hpa,pods -l app=nginx-hpa
	kubectl get pod load-generator --ignore-not-found

clean:
	kubectl delete -f generator.yaml --ignore-not-found

destroy:
	./cleanup.sh
