# Submodule directories (extracted from .gitmodules)
SUBMODULES := BioMate genomics-status StatusDB_NGI Yggdrasil demux_realm

help: ## Show this help
	@echo "Usage: make [target] [TARGET]"
	@echo ""
	@echo "All-submodule targets:"
	@echo "  init           Initialize and clone all submodules"
	@echo "  status         Show status of all submodules"
	@echo "  update-all     Update all submodules to the latest of their current branch"
	@echo "  sync           Sync submodule remotes with .gitmodules"
	@echo "  reset          Force all submodules to the commits recorded by the repo"
	@echo "  use-dev        Switch the repo to 'dev' and pin submodules to its commits"
	@echo "  use-main       Switch the repo to 'main' (or 'master') and pin submodule commits"
	@echo "  extract-deps   Extract deps and show how to add them via pixi"
	@echo ""
	@echo "Compose targets (Yggdrasil workflow testing environment):"
	@echo "  compose-up                Build and start the stack (statusdb, biomate, yggdrasil)"
	@echo "  compose-up-full           Same as compose-up plus genomics-status (profile full)"
	@echo "  compose-up-statusdb       Build and start only statusdb"
	@echo "  compose-up-biomate        Build and start only biomate"
	@echo "  compose-up-yggdrasil      Build and start yggdrasil (plus its deps)"
	@echo "  compose-up-genomics-status  Build and start genomics-status (profile full)"
	@echo "  compose-rebuild           Rebuild all images without cache and recreate the stack"
	@echo "  compose-rebuild-full      Same, plus genomics-status (profile full)"
	@echo "  compose-down              Stop and remove the stack (volumes are kept)"
	@echo "  compose-logs              Follow yggdrasil logs"
	@echo "  compose-ps                Show stack status"
	@echo "  compose-reset             Stop the stack and remove all volumes"
	@echo "  compose-scenario          Inject a fresh test scenario into a running stack"
	@echo "  compose-seed-status       Inject the BioMate status seeds (opt-in) into a running stack"
	@echo ""
	@echo "Per-submodule targets (replace TARGET with one of: $(SUBMODULES))"
	@echo "  update-TARGET  Update a single submodule to the latest of its current branch"
	@echo "  status-TARGET  Show status for a single submodule"

# Clone submodules that are not checked out yet. Already-initialized
# submodules are left exactly as-is (no branch switching, no reset):
# `status` prefixes uninitialized submodules with '-'.
init:
	@for path in $$(git submodule status | awk '$$1 ~ /^-/ {print $$2}'); do \
		echo "Initializing submodule '$$path'..."; \
		git submodule update --init --recursive -- "$$path"; \
	done
	@git submodule status

extract-deps:
	@DEPS=$$(python3 $(CURDIR)/extract_deps.py 2>&1); \
	ONELINES=$$(echo "$$DEPS" | head -1); \
	SPECIAL=$$(echo "$$DEPS" | tail -n +2); \
	echo "pixi add $$ONELINES"; \
	if [ -n "$$SPECIAL" ]; then \
		echo "─────────────────────────────────────────────────────────────────"; \
		echo "$$SPECIAL"; \
	fi

status:
	@git submodule status

sync:
	@git submodule sync

# Force every submodule back to the commit recorded by the top-level repo,
# discarding uncommitted changes and untracked files along the way.
reset:
	@git submodule foreach --recursive 'git clean -fd'
	@git submodule update --init --force --recursive
	@git submodule status

# Switch the top-level repository to the given branch and check out the
# submodule commits pinned by that branch. Submodules are never switched
# to a branch themselves: they are left detached at the pinned commits.
# Submodules with uncommitted changes are left as-is, with a warning.
# Argument 1: branch name; argument 2: fallback branch name (optional).
define USE_BRANCH
@branch="$(1)"; \
if git rev-parse --verify --quiet refs/heads/$$branch >/dev/null; then \
	git checkout "$$branch" || exit 1; \
elif git rev-parse --verify --quiet refs/remotes/origin/$$branch >/dev/null; then \
	echo "No local branch '$$branch'; creating it from origin/$$branch"; \
	git checkout -b "$$branch" "origin/$$branch" || exit 1; \
else \
	fallback="$(2)"; \
	if [ -n "$$fallback" ] && git rev-parse --verify --quiet refs/heads/$$fallback >/dev/null; then \
		echo "No branch '$(1)' found; using '$(2)' instead"; \
		git checkout "$$fallback" || exit 1; \
	elif [ -n "$$fallback" ] && git rev-parse --verify --quiet refs/remotes/origin/$$fallback >/dev/null; then \
		echo "No branch '$(1)' found; creating '$(2)' from origin/$$fallback"; \
		git checkout -b "$$fallback" "origin/$$fallback" || exit 1; \
	else \
		echo "Error: branch '$(1)' not found (locally or on origin)"; \
		exit 1; \
	fi; \
fi; \
for sub in $(SUBMODULES); do \
	modpath=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
	if [ -n "$$modpath" ] && [ -d "$$modpath" ] && [ -n "$$(git -C "$$modpath" status --porcelain 2>/dev/null)" ]; then \
		echo "WARNING: '$$sub' has uncommitted changes; leaving it at its current commit"; \
	fi; \
done; \
echo "Checking out the submodule commits pinned by the branch..."; \
git submodule update --init --recursive || echo "WARNING: some submodules were not updated (see messages above)"; \
git submodule status
endef

# Switch the repo to the 'dev' branch and pin the submodules to its commits.
use-dev:
	$(call USE_BRANCH,dev,)

# Switch the repo to the 'main' branch ('master' as fallback) and pin the
# submodules to its commits.
use-main:
	$(call USE_BRANCH,main,master)

# Per-submodule status
status-%:
	@MODULE="$*"; \
	MODPATH=$$(git config --file .gitmodules submodule.$$MODULE.path 2>/dev/null); \
	if [ -z "$$MODPATH" ]; then \
		echo "Error: No submodule named '$$MODULE' found"; \
		exit 1; \
	fi; \
	git submodule status -- "$$MODPATH"

# Update one submodule to the latest commit of its current local branch
# (never switches branches). Submodules that are not cloned yet are
# initialized at their pinned commit; detached submodules only fetch,
# since there is no branch to pull. Shared by update-all and update-%.
define UPDATE_SUBMODULE
update_submodule() { \
	sub="$$1"; \
	modpath=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
	if [ -z "$$modpath" ]; then \
		echo "WARNING: No .gitmodules entry for '$$sub'"; \
		return 1; \
	fi; \
	if [ ! -e "$$modpath/.git" ]; then \
		echo "Initializing '$$sub' (not cloned yet)..."; \
		git submodule update --init --recursive -- "$$modpath" || { echo "WARNING: Could not initialize $$sub"; return 0; }; \
		return 0; \
	fi; \
	branch=$$(cd "$$modpath" && git rev-parse --abbrev-ref HEAD 2>/dev/null); \
	if [ "$$branch" = "HEAD" ]; then \
		sha=$$(cd "$$modpath" && git rev-parse --short HEAD 2>/dev/null); \
		echo "$$sub is detached at $${sha:-unknown}; fetching remotes only (no branch to update)"; \
		git -C "$$modpath" fetch --all || echo "WARNING: Could not fetch $$sub"; \
		return 0; \
	fi; \
	if [ -z "$$branch" ]; then \
		echo "WARNING: Could not determine current branch for $$sub, skipping"; \
		return 0; \
	fi; \
	echo "Updating '$$sub' (branch: $$branch)..."; \
	git -C "$$modpath" pull --rebase origin $$branch || echo "WARNING: Could not update $$sub"; \
	return 0; \
};
endef

update-%:
	@$(call UPDATE_SUBMODULE) update_submodule $*

update-all: sync
	@$(call UPDATE_SUBMODULE) for sub in $(SUBMODULES); do update_submodule "$$sub" || true; done; git submodule status

# ---------------------------------------------------------------------------
# Compose testing environment (Yggdrasil workflow)
# ---------------------------------------------------------------------------
COMPOSE := docker compose

# Web-service links printed after a successful "up".
# Argument 1: optional extra link lines (e.g. profile-gated services),
# each prefixed with $(TAB) so they land on their own recipe line.
TAB := $(empty) $(empty)

# Credentials: if the user overrides STACK_COUCH_USER/PASSWORD (via
# environment or `make VAR=...`), print the variable name instead of the
# value. Empty values fall back to the defaults, matching docker-compose.
# The name is emitted as '$$VAR' so the shell prints the literal
# '$VAR'; the value is single-quoted at the printf call site, outside
# the double quotes, to keep the shell from expanding it.
ifneq (,$(and $(filter environment command line,$(origin STACK_COUCH_USER)),$(STACK_COUCH_USER)))
	CREDENTIAL_USER = $$STACK_COUCH_USER
else
	CREDENTIAL_USER = admin
endif
ifneq (,$(and $(filter environment command line,$(origin STACK_COUCH_PASSWORD)),$(STACK_COUCH_PASSWORD)))
	CREDENTIAL_PASSWORD = $$STACK_COUCH_PASSWORD
else
	CREDENTIAL_PASSWORD = secret
endif

define COMPOSE_LINKS
	@echo ""
	@echo "Stack is up. Web services:"
	@printf '  StatusDB (CouchDB Fauxton): http://localhost:5984/_utils/  (login: %s / %s)\n' '$(CREDENTIAL_USER)' '$(CREDENTIAL_PASSWORD)'
	@echo "  BioMate:                    http://localhost:8765"
$(1)
endef

compose-up: ## Build and start statusdb, biomate and yggdrasil
	$(COMPOSE) up -d --build
	$(call COMPOSE_LINKS,)

compose-build-gs-base: ## Build the genomics-status base image (conda env)
	docker build -q -t dataflow-genomics-status-base:latest ./genomics-status

compose-up-full: compose-build-gs-base ## compose-up plus genomics-status (profile "full")
	$(COMPOSE) --profile full up -d --build
	$(call COMPOSE_LINKS,$(TAB)@echo "  Genomics Status:            http://localhost:9761")

# Per-service targets (mainly for testing). Compose also starts the
# depends_on closure of the requested service.
compose-up-statusdb: ## Build and start only statusdb
	$(COMPOSE) up -d --build statusdb

compose-up-biomate: ## Build and start only biomate
	$(COMPOSE) up -d --build biomate

compose-up-yggdrasil: ## Build and start yggdrasil (plus its deps: statusdb, biomate)
	$(COMPOSE) up -d --build yggdrasil

compose-up-genomics-status: compose-build-gs-base ## genomics-status (profile "full"; plus statusdb)
	$(COMPOSE) --profile full up -d --build genomics-status

# Rebuild images without any cache, then recreate the containers on the
# fresh images. --force-recreate makes the recreation explicit even if a
# rebuild happened to produce the same image ID.
compose-rebuild: ## Rebuild all images without cache and recreate the stack
	$(COMPOSE) build --no-cache
	$(COMPOSE) up -d --force-recreate
	$(call COMPOSE_LINKS,)

# The genomics-status app image builds on a base image that compose never
# rebuilds itself, so the base is no-cache-rebuilt inline first (same build
# as compose-build-gs-base, plus --no-cache).
compose-rebuild-full: ## No-cache rebuild, plus genomics-status (profile "full")
	docker build -q --no-cache -t dataflow-genomics-status-base:latest ./genomics-status
	$(COMPOSE) --profile full build --no-cache
	$(COMPOSE) --profile full up -d --force-recreate
	$(call COMPOSE_LINKS,$(TAB)@echo "  Genomics Status:            http://localhost:9761")

# Teardown always passes --profile full so profile-gated services
# (genomics-status) are covered no matter how the stack was started;
# down only acts on containers that exist.
compose-down: ## Stop and remove the stack (volumes are kept)
	$(COMPOSE) --profile full down --remove-orphans

compose-logs: ## Follow yggdrasil logs
	$(COMPOSE) logs -f yggdrasil

compose-ps: ## Show stack status
	$(COMPOSE) ps

compose-reset: ## Stop the stack and remove all volumes (fresh CouchDB on next up)
	$(COMPOSE) --profile full down -v --remove-orphans

compose-scenario: ## Inject a fresh test scenario into a running stack
	@curl -sf -X PUT \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		-H 'Content-Type: application/json' \
		--data-binary @deploy/seed/test_scenario_happy_path.json \
		"http://localhost:5984/yggdrasil/test_scenario:manual-$$(date +%s)" && \
		echo "Scenario injected; watch it with: make compose-logs"

# Opt-in seeding of the BioMate workflow documents. Each seed keeps the
# _id from the file (deterministic, idempotent). _id/_rev are stripped from
# the PUT body: a _rev in the body makes CouchDB treat the PUT as a
# revisioned update, which 409s for a new document.
compose-seed-status: ## Inject the BioMate flowcell_status + demux_sample_info seeds into a running stack
	@for f in flowcell_status demux_sample_info; do \
		id=$$(python3 -c "import json; print(json.load(open('deploy/seed/$${f}_biomate.json'))['_id'])"); \
		code=$$(curl -s -o /dev/null -w '%{http_code}' \
			-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
			"http://localhost:5984/$${f}/$${id}"); \
		if [ "$${code}" = "404" ]; then \
			body=$$(python3 -c "import json, sys; d = json.load(open(sys.argv[1])); d.pop('_id', None); d.pop('_rev', None); print(json.dumps(d))" "deploy/seed/$${f}_biomate.json") && \
			curl -sf -X PUT \
				-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
				-H 'Content-Type: application/json' \
				--data-binary "$${body}" \
				"http://localhost:5984/$${f}/$${id}" >/dev/null && \
			echo "Seeded $${f} doc '$${id}'"; \
		else \
			echo "$${f} doc '$${id}' already present (HTTP $${code}); skipping"; \
		fi; \
	done
