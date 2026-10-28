# Makefile

# Submodule directories (extracted from .gitmodules)
SUBMODULES := BioMate genomics-status StatusDB_NGI Yggdrasil demux_realm

help: ## Show this help
	@echo "Usage: make [target] [TARGET]"
	@echo ""
	@echo "All-submodule targets:"
	@echo "  init           Register and initialize root modules; clone missing genomics-status/nvd3"
	@echo "  deinit         Remove all submodule worktrees and Git data (CONFIRM=1 required)"
	@echo "  deinit-all     Alias for deinit"
	@echo "  status         Show status of all submodules"
	@echo "  update-all     Advance all submodules to their current branch's latest commit"
	@echo "  sync           Sync submodule remotes with .gitmodules"
	@echo "  reset          Destructively reset submodules to the commits recorded by the repo"
	@echo "  use-dev        Switch the repo to 'dev' and pin submodules to its commits"
	@echo "  use-main       Switch the repo to 'main' (or 'master') and pin submodule commits"
	@echo "  extract-deps   Extract deps and show how to add them via pixi"
	@echo ""
	@echo "Compose targets (Yggdrasil workflow testing environment):"
	@echo "  compose-up                Build and start the stack (statusdb, yggdrasil)"
	@echo "  compose-up-full           Same as compose-up plus biomate + genomics-status (profile full)"
	@echo "  compose-up-statusdb       Build and start only statusdb"
	@echo "  compose-up-biomate        Build and start only biomate (profile full)"
	@echo "  compose-up-yggdrasil      Build and start yggdrasil (plus its dep: statusdb)"
	@echo "  compose-up-genomics-status  Build and start genomics-status (profile full)"
	@echo "  compose-rebuild           Rebuild statusdb + yggdrasil images without cache; recreate the stack"
	@echo "  compose-rebuild-full      Same, plus biomate and genomics-status (profile full)"
	@echo "  compose-down              Stop and remove the stack (volumes are kept)"
	@echo "  compose-logs              Follow yggdrasil logs"
	@echo "  compose-ps                Show stack status"
	@echo "  compose-reset             Stop the stack and remove all volumes"
	@echo "  compose-scenario          Inject a fresh test scenario into a running stack"
	@echo "  compose-seed-status       Inject the BioMate status seeds (opt-in) into a running stack"
	@echo "  compose-trigger           Re-touch the seeded docs to re-fire the demux workflow (DBS=)"
	@echo "  compose-inject            Inject fresh generated flowcells into a running stack (COUNT= LANES= DIR=)"
	@echo ""
	@echo "Per-submodule targets (replace TARGET with one of: $(SUBMODULES))"
	@echo "  init-TARGET    Register, sync, and initialize one submodule"
	@echo "  deinit-TARGET  Remove one submodule's worktree and Git data (CONFIRM=1 required)"
	@echo "  update-TARGET  Pull latest for a single submodule"
	@echo "  status-TARGET  Show status for a single submodule"

# Clone submodules that are not checked out yet. Already-initialized
# submodules are left exactly as-is (no branch switching, no reset):
# `status` prefixes uninitialized submodules with '-'.
init:
	@failed=0; for sub in $(SUBMODULES); do $(MAKE) --no-print-directory -f "$(abspath $(lastword $(MAKEFILE_LIST)))" init-target SUBMODULE="$$sub" || failed=1; done; exit "$$failed"

init-%:
	@$(MAKE) --no-print-directory -f "$(abspath $(lastword $(MAKEFILE_LIST)))" init-target SUBMODULE="$*"

init-target:
	@sub="$(SUBMODULE)"; \
	if [ -d "$$sub" ]; then \
		if [ "$$($(git submodule status "$$sub" | cut -c1))" = "-" ]; then \
			$(git submodule init "$$sub" && git submodule update "$$sub") || exit 1; \
		else \
			echo "$$sub already initialized"; \
		fi \
	else \
		$(git submodule add --name "$$sub" git@github.com:ngi-sweden/$$sub.git "$$sub") || exit 1; \
	fi

deinit:
	@$(MAKE) --no-print-directory -f "$(abspath $(lastword $(MAKEFILE_LIST)))" deinit-all

deinit-all:
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "ERROR: deinit requires CONFIRM=1"; \
		exit 1; \
	fi
	@failed=0; for sub in $(SUBMODULES); do $(MAKE) --no-print-directory -f "$(abspath $(lastword $(MAKEFILE_LIST)))" deinit-target SUBMODULE="$$sub" || failed=1; done; exit "$$failed"

deinit-%:
	@$(MAKE) --no-print-directory -f "$(abspath $(lastword $(MAKEFILE_LIST)))" deinit-target SUBMODULE="$*"

deinit-target:
	@sub="$(SUBMODULE)"; \
	if [ -d "$$sub" ]; then \
		if [ "$$($(git submodule status "$$sub" | cut -c1))" != "-" ]; then \
			$(git submodule deinit -f "$$sub" && git rm -f "$$sub" && rm -rf .git/modules/$$sub) || exit 1; \
		else \
			rm -rf "$$sub"; \
		fi \
	else \
		echo "$$sub not found"; \
	fi

update-all:
	@$(git submodule update --remote)

update-%:
	@$(git submodule update --remote "$(SUBMODULE)")

status:
	@$(git submodule status --recursive)

status-%:
	@$(git submodule status "$(SUBMODULE)")

sync:
	@$(git submodule sync --recursive)

reset:
	@$(git submodule foreach --recursive 'git reset --hard')

use-dev:
	@$(git submodule foreach --recursive 'branch=$$(git config -f $$toplevel/.gitmodules submodule.$$name.branch); \
		if [ "$$branch" = "dev" ]; then \
			git checkout dev && git pull; \
		else \
			git checkout $$branch; \
		fi')

use-main:
	@$(git submodule foreach --recursive 'branch=$$(git config -f $$toplevel/.gitmodules submodule.$$name.branch); \
		if [ "$$branch" = "main" ] || [ "$$branch" = "master" ]; then \
			if [ "$$branch" = "main" ]; then git checkout main; else git checkout master; fi && git pull; \
		else \
			git checkout $$branch; \
		fi')

extract-deps:
	@python3 extract_deps.py

# Compose targets
COMPOSE ?= docker compose
COMPOSE_FILE ?= docker-compose.yml
COMPOSE_PROJECT_NAME ?= dataflow

# Profiles for compose-up-full (biomate, genomics-status, dind)
FULL_LINKS := full dind

# Set COMPOSE_PROFILES from FULL_LINKS when COMPOSE_LINKS is 'full'
# Otherwise, COMPOSE_LINKS can be a single profile name.
COMPOSE_LINKS ?= $(FULL_LINKS)

COMPOSE := $(COMPOSE) -f $(COMPOSE_FILE) -p $(COMPOSE_PROJECT_NAME)

$(COMPOSE):
	@command -v docker > /dev/null || (echo "ERROR: docker not found"; exit 1)

ifeq ($(COMPOSE_LINKS),full)
$(COMPOSE): COMPOSE_PROFILES := $(FULL_LINKS)
endif

# Build and start the stack (statusdb + yggdrasil)
compose-up: ## Build and start the stack (statusdb, yggdrasil)
	$(COMPOSE) up -d

# Build and start the full stack (with biomate + genomics-status)
compose-up-full: ## Build and start the stack (statusdb, yggdrasil, biomate, genomics-status)
	$(COMPOSE) --profile full up -d

# Build and start only statusdb
compose-up-statusdb: ## Build and start only statusdb
	$(COMPOSE) up -d statusdb

# Build and start only biomate (profile full)
compose-up-biomate: ## Build and start only biomate (profile full)
	$(COMPOSE) --profile full up -d biomate

# Build and start only yggdrasil (plus its dep: statusdb)
compose-up-yggdrasil: ## Build and start yggdrasil (plus its dep: statusdb)
	$(COMPOSE) up -d yggdrasil

# Build and start only genomics-status (profile full)
compose-up-genomics-status: ## Build and start genomics-status (profile full)
	$(COMPOSE) --profile full up -d genomics-status

# Rebuild images without cache and recreate the stack
compose-rebuild: ## Rebuild statusdb + yggdrasil images without cache; recreate the stack
	$(COMPOSE) build --no-cache && $(COMPOSE) up -d --force-recreate

# Rebuild full stack images without cache and recreate
compose-rebuild-full: ## Rebuild all images without cache; recreate the stack (profile full)
	$(COMPOSE) --profile full build --no-cache && $(COMPOSE) --profile full up -d --force-recreate

# Teardown always passes --profile full and --profile dind so profile-gated
# services (biomate, genomics-status, the dind sidecar) are covered no matter
# how the stack was started; down only acts on containers that exist.
compose-down: ## Stop and remove the stack (volumes are kept)
	$(COMPOSE) --profile full --profile dind down --remove-orphans

compose-logs: ## Follow yggdrasil logs
	$(COMPOSE) logs -f yggdrasil

compose-ps: ## Show stack status
	$(COMPOSE) ps

compose-reset: ## Stop the stack and remove all volumes (fresh CouchDB on next up)
	$(COMPOSE) --profile full --profile dind down -v --remove-orphans

compose-scenario: ## Inject a fresh test scenario into a running stack
	@curl -sf -X PUT \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		-H 'Content-Type: application/json' \
		--data-binary @deploy/seed/test_scenario_happy_path.json \
		"http://localhost:5984/yggdrasil_testdocs/test_scenario:manual-$$(date +%s)" && \
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

# Knobs for compose-trigger / compose-inject (see below).
DBS ?= flowcell_status demux_sample_info
COUNT ?= 1
LANES ?=
DIR ?=

# Re-touch the seeded BioMate docs so the watcher re-fires the demux
# workflow. The mutation is repeatable: a timestamp is rewritten to the
# current time on every run, so each invocation lands a fresh revision
# (flowcell_status: last event; demux_sample_info: first_generated).
# DBS= selects which docs to touch.
compose-trigger: ## Re-touch the seeded docs to re-fire the demux workflow (DBS=)
	@for f in $(DBS); do \
		id=$$(python3 -c "import json; print(json.load(open('deploy/seed/$${f}_biomate.json'))['_id'])"); \
		code=$$(curl -s -o /dev/null -w '%{http_code}' \
			-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
			"http://localhost:5984/$${f}/$${id}"); \
		if [ "$${code}" = "404" ]; then \
			echo "error: $${f} doc '$${id}' not found (HTTP 404) - is the stack up and seeded? try: make compose-up && make compose-seed-status"; \
		elif [ "$${f}" = "demux_sample_info" ]; then \
			now=$$(date -u +%Y-%m-%dT%H:%M:%S.000+00:00); \
			body=$$(curl -s -u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" "http://localhost:5984/$${f}/$${id}" | \
				python3 -c "import json, sys; d = json.load(sys.stdin); d['metadata']['first_generated'] = sys.argv[1]; print(json.dumps(d))" "$${now}") && \
			curl -sf -X PUT \
				-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
				-H 'Content-Type: application/json' \
				--data-binary "$${body}" \
				"http://localhost:5984/$${f}/$${id}" >/dev/null && \
			echo "Touched $${f} doc '$${id}' (first_generated -> $${now})"; \
		else \
			now=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
			body=$$(curl -s -u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" "http://localhost:5984/$${f}/$${id}" | \
				python3 -c "import json, sys; d = json.load(sys.stdin); d['events'][-1]['timestamp'] = sys.argv[1]; print(json.dumps(d))" "$${now}") && \
			curl -sf -X PUT \
				-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
				-H 'Content-Type: application/json' \
				--data-binary "$${body}" \
				"http://localhost:5984/$${f}/$${id}" >/dev/null && \
			echo "Touched $${f} doc '$${id}' (last event -> $${now})"; \
		fi; \
	done
	@echo "Watch the workflow with: make compose-logs"

# Inject fresh flowcell documents into a running stack. The templates are
# the LIVE docs in the database (fetched by _id from the seed files) and
# the output is generated on the fly by deploy/seed/generate_flowcell.py:
#   random mode (default): COUNT new flowcells with fresh
#     flowcell/runfolder ids, remapped projects/samples and event
#     timestamps rebased to now;
#   DIR mode: builds the docs from the SampleSheet.csv of a real run
#     folder (e.g. DIR=BioMate/temp), upserted by flowcell_id, so
#     re-injecting the same run folder replaces the existing docs.
#   COUNT= number of flowcells (random mode, default 1)
#   LANES= lane count (default: the template's)
#   DIR=   run folder to build the docs from (implies COUNT=1)
compose-inject: ## Inject fresh generated flowcells into a running stack (COUNT= LANES= DIR=)
	@f_id=$$(python3 -c "import json; print(json.load(open('deploy/seed/flowcell_status_biomate.json'))['_id'])"); \
	d_id=$$(python3 -c "import json; print(json.load(open('deploy/seed/demux_sample_info_biomate.json'))['_id'])"); \
	extra=""; \
	if [ -n "$(LANES)" ]; then extra="$$extra --lanes $(LANES)"; fi; \
	if [ -n "$(DIR)" ]; then extra="$$extra --dir $(DIR)"; fi; \
	python3 deploy/seed/generate_flowcell.py \
		--base-url http://localhost:5984 \
		--user "$${STACK_COUCH_USER:-admin}" \
		--password "$${STACK_COUCH_PASSWORD:-secret}" \
		--count $(COUNT) \
		--template-flowcell-id "$${f_id}" \
		--template-demux-id "$${d_id}" \
		$$extra
