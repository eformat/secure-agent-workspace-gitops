ARGO_NS := openshift-gitops
ROOT_APP := secure-agent-workspace
REPO_URL ?= $(shell git remote get-url origin 2>/dev/null | sed 's|git@\([^:]*\):\(.*\)\.git$$|https://\1/\2|' || echo https://github.com/eformat/secure-agent-workspace-gitops.git)

.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

.PHONY: help
help: ## Print this help message
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: bootstrap
bootstrap: ## Apply bootstrap RBAC + root Application (repoURL resolved from git remote)
	@oc apply -f bootstrap/
	@for f in app-of-apps/root-application.yaml app-of-apps/hub/*.yaml; do \
		sed "s|REPO_URL_PLACEHOLDER|$(REPO_URL)|g" $$f | oc apply -n $(ARGO_NS) -f -; \
	done
	@echo "Root application applied (repoURL: $(REPO_URL))"

.PHONY: wait
wait: ## Poll root Application sync/health until converged
	@for i in $$(seq 1 60); do \
		sync=$$(oc get application $(ROOT_APP) -n $(ARGO_NS) -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown); \
		health=$$(oc get application $(ROOT_APP) -n $(ARGO_NS) -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown); \
		echo "sync=$$sync health=$$health ($$i/60)"; \
		if [ "$$sync" = "Synced" ] && [ "$$health" = "Healthy" ]; then exit 0; fi; \
		sleep 10; \
	done; exit 1

.PHONY: destroy
destroy: ## Delete root Application (prune cascades to children)
	@oc delete application $(ROOT_APP) -n $(ARGO_NS) --ignore-not-found

.PHONY: destroy-olm
destroy-olm: ## Delete OLM subscriptions + operator namespaces left after prune
	@oc delete subscription eso -n external-secrets-operator --ignore-not-found
	@oc delete subscription openshift-virtualization -n openshift-cnv --ignore-not-found
	@oc delete subscription rhbk -n openshell-agents --ignore-not-found
	@oc delete subscription rhdh -n rhdh-operator --ignore-not-found
	@oc delete subscription openshift-ai -n redhat-ods-operator --ignore-not-found

.PHONY: seed-vault
seed-vault: ## Seed vault with sandbox ssh keypair + inference api key
	@secrets/seed-vault.sh
