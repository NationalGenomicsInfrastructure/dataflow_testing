# Makefile

# Submodule directories (extracted from .gitmodules)
SUBMODULES := BioMate genomics-status StatusDB_NGI Yggdrasil demux_realm

# Command-like targets: force make to always run them, even if a file
# or directory with the same name exists.
.PHONY: help init init-% init-target deinit deinit-all deinit-% deinit-target \
        update-all update-% status status-% sync reset use-dev use-main extract-deps \
        compose-build-yggdrasil compose-build-gs-base compose-up compose-up-full \
        compose-up-statusdb compose-up-biomate compose-up-yggdrasil compose-up-genomics-status \
        compose-rebuild compose-rebuild-full compose-down compose-logs compose-ps compose-reset \
        compose-scenario compose-seed-status compose-trigger compose-inject compose-sync-flowcell

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
	@echo "  compose-build-yggdrasil   Build the base + dind-flavoured yggdrasil images"
	@echo "  compose-build-gs-base     Build the genomics-status base image (conda env)"
	@echo "  compose-rebuild           Rebuild statusdb + yggdrasil images without cache; recreate the stack"
	@echo "  compose-rebuild-full      Same, plus biomate and genomics-status (profile full)"
	@echo "  compose-down              Stop and remove the stack (volumes are kept)"
	@echo "  compose-logs              Follow yggdrasil logs"
	@echo "  compose-ps                Show stack status"
	@echo "  compose-reset             Stop the stack and remove all volumes"
	@echo "  compose-reset-statusdb    Reset CouchDB while Yggdrasil is paused; preserve files (CONFIRM=1)"
	@echo "  compose-reset-work        Pause Yggdrasil, clear /work, and resume it (CONFIRM=1)"
	@echo "  compose-scenario          Inject a fresh test scenario into a running stack"
	@echo "  compose-seed-status       Inject the BioMate status seeds (opt-in) into a running stack"
	@echo "  compose-trigger           Re-touch the seeded docs to re-fire the demux workflow (DBS=)"
	@echo "  compose-trigger-rerun     Increment run_token on documents in yggdrasil_plans"
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
		if [ "$$($$(git submodule status "$$sub" | cut -c1))" = "-" ]; then \
			git submodule init "$$sub" && git submodule update "$$sub" || exit 1; \
		else \
			echo "$$sub already initialized"; \
		fi \
	else \
		git submodule add --name "$$sub" git@github.com:NationalGenomicsInfrastructure/$$sub.git "$$sub" || exit 1; \
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
		if [ "$$($$(git submodule status "$$sub" | cut -c1))" != "-" ]; then \
			git submodule deinit -f "$$sub" && git rm -f "$$sub" && rm -rf .git/modules/$$sub || exit 1; \
		else \
			rm -rf "$$sub"; \
		fi \
	else \
		echo "$$sub not found"; \
	fi

update-all:
	@git submodule update --remote

update-%:
	@git submodule update --remote "$(SUBMODULE)"

status:
	@git submodule status --recursive

status-%:
	@git submodule status "$(SUBMODULE)"

sync:
	@git submodule sync --recursive

reset:
	@git submodule foreach --recursive 'git reset --hard'

use-dev:
	@git submodule foreach --recursive 'branch=$$(git config -f $$toplevel/.gitmodules submodule.$$name.branch); \
		if [ "$$branch" = "dev" ]; then \
			git checkout dev && git pull; \
		else \
			git checkout $$branch; \
		fi'

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

# Advance one submodule without switching the parent repository branch.
# Attached submodules follow their configured upstream; detached submodules
# advance to origin's default branch and remain detached. Shared by update-all
# and update-%.
define UPDATE_SUBMODULE
update_submodule() { \
	sub="$$1"; \
	modpath=$$(git config --file .gitmodules submodule.$$sub.path 2>/dev/null); \
	if [ -z "$$modpath" ]; then \
		echo "WARNING: No .gitmodules entry for '$$sub'"; \
		return 1; \
	fi; \
	echo "Fetching remotes for '$$sub'..."; \
	git -C "$$modpath" fetch --all || { \
		echo "WARNING: Could not fetch '$$sub'; skipping update"; \
		return 1; \
	}; \
	branch=$$(git -C "$$modpath" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""; \
	if [ -z "$$branch" ]; then \
		upstream=$$(git -C "$$modpath" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || upstream=""; \
		if [ -z "$$upstream" ]; then \
			echo "WARNING: origin/HEAD is not available for '$$sub'"; \
			return 1; \
		fi; \
		git -C "$$modpath" checkout --detach "$$upstream" || { echo "WARNING: Could not advance '$$sub' to $$upstream"; return 1; }; \
		echo "Updated '$$sub' to $$upstream (still detached)"; \
		return 0; \
	fi; \
	upstream=$$(git -C "$$modpath" rev-parse --abbrev-ref --symbolic-full-name "$$branch@{upstream}" 2>/dev/null) || upstream=""; \
	if [ -z "$$upstream" ]; then \
		echo "WARNING: '$$sub' branch '$$branch' has no configured upstream"; \
		return 1; \
	fi; \
	if git -C "$$modpath" merge-base --is-ancestor HEAD "$$upstream"; then \
		echo "Updating '$$sub' ($$branch) to $$upstream..."; \
		git -C "$$modpath" merge --ff-only "$$upstream" || { echo "WARNING: Could not fast-forward '$$sub'"; return 1; }; \
	elif git -C "$$modpath" merge-base --is-ancestor "$$upstream" HEAD; then \
		echo "'$$sub' is already ahead of $$upstream; leaving it unchanged"; \
	else \
		echo "WARNING: '$$sub' branch '$$branch' has diverged from $$upstream; refusing to rewrite local history"; \
		return 1; \
	fi; \
	return 0; \
};
endef

update-%:
	@$(call UPDATE_SUBMODULE) update_submodule $*

update-all: sync
	@$(call UPDATE_SUBMODULE) failed=0; for sub in $(SUBMODULES); do update_submodule "$$sub" || failed=1; done; git submodule status || failed=1; exit "$$failed"

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

# The yggdrasil service runs the dind-flavoured image
# (deploy/Dockerfile.yggdrasil.dind), layered ON TOP of the base image
# (deploy/Dockerfile.yggdrasil). Compose can't express that dependency
# between two builds, so the Makefile builds both explicitly (the compose
# file references the resulting image names only). Both builds are cheap
# when nothing changed (layer caching), so they run as a prerequisite of
# every up target that starts yggdrasil.
YGG_BASE_IMAGE := dataflow-yggdrasil:latest
YGG_DIND_IMAGE := dataflow-yggdrasil-dind:latest

YGG_NO_CACHE ?=

compose-build-yggdrasil: ## Build the base + dind-flavoured yggdrasil images
	docker build -q $(YGG_NO_CACHE) -t $(YGG_BASE_IMAGE) -f deploy/Dockerfile.yggdrasil .
	docker build -q $(YGG_NO_CACHE) -t $(YGG_DIND_IMAGE) -f deploy/Dockerfile.yggdrasil.dind .

# The genomics-status service (profile "full") builds from
# deploy/Dockerfile.genomics-status, which is layered ON TOP of
# dataflow-genomics-status-base:latest (the conda/pip environment image,
# built from the genomics-status submodule's own Dockerfile). Compose
# never builds that base itself, so this target does; it is a prerequisite
# of the up targets that build/start genomics-status.
GS_BASE_IMAGE := dataflow-genomics-status-base:latest

compose-build-gs-base: ## Build the genomics-status base image (conda env)
	docker build -q -t $(GS_BASE_IMAGE) ./genomics-status

# Build and start the stack (statusdb + yggdrasil)
compose-up: compose-build-yggdrasil ## Build and start the stack (statusdb, yggdrasil)
	$(COMPOSE) up -d

# Build and start the full stack (with biomate + genomics-status)
compose-up-full: compose-build-gs-base compose-build-yggdrasil ## Build and start the stack (statusdb, yggdrasil, biomate, genomics-status)
	$(COMPOSE) --profile full up -d

# Build and start only statusdb
compose-up-statusdb: ## Build and start only statusdb
	$(COMPOSE) up -d statusdb

# Build and start only biomate (profile full)
compose-up-biomate: ## Build and start only biomate (profile full)
	$(COMPOSE) --profile full up -d biomate

# Build and start only yggdrasil (plus its dep: statusdb)
compose-up-yggdrasil: compose-build-yggdrasil ## Build and start yggdrasil (plus its dep: statusdb)
	$(COMPOSE) up -d yggdrasil

# Build and start only genomics-status (profile full)
compose-up-genomics-status: compose-build-gs-base ## Build and start genomics-status (profile full)
	$(COMPOSE) --profile full up -d genomics-status

# Rebuild images without cache and recreate the stack. The yggdrasil
# images are built outside compose (see compose-build-yggdrasil), so they
# get the same --no-cache treatment via YGG_NO_CACHE.
compose-rebuild: ## Rebuild statusdb + yggdrasil images without cache; recreate the stack
	$(COMPOSE) build --no-cache
	$(MAKE) compose-build-yggdrasil YGG_NO_CACHE=--no-cache
	$(COMPOSE) up -d --force-recreate

# Rebuild full stack images without cache and recreate. The genomics-status
# base image is no-cache-rebuilt inline first, as compose never builds it
# (same build as compose-build-gs-base, plus --no-cache).
compose-rebuild-full: ## Rebuild all images without cache; recreate the stack (profile full)
	docker build -q --no-cache -t $(GS_BASE_IMAGE) ./genomics-status
	$(COMPOSE) --profile full build --no-cache
	$(MAKE) compose-build-yggdrasil YGG_NO_CACHE=--no-cache
	$(COMPOSE) --profile full up -d --force-recreate

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

compose-reset-statusdb: ## Reset databases through the running CouchDB API while Yggdrasil is paused (CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "ERROR: This deletes all databases in the statusdb container; rerun with CONFIRM=1"; \
		exit 1; \
	fi
	@set -eu; \
	paused=0; \
	ygg_container=$$($(COMPOSE) ps -q yggdrasil); \
	if [ -n "$$ygg_container" ]; then \
		ygg_state=$$(docker inspect --format '{{.State.Running}} {{.State.Paused}}' "$$ygg_container"); \
		if [ "$$ygg_state" = "true false" ]; then \
			$(COMPOSE) pause yggdrasil; \
			paused=1; \
			trap '$(COMPOSE) unpause yggdrasil' 0; \
			trap 'exit 130' INT; \
			trap 'exit 143' TERM; \
		fi; \
	fi; \
	$(COMPOSE) exec -T statusdb bash -euc ' \
		auth="$${COUCHDB_USER:?}:$${COUCHDB_PASSWORD:?}"; \
		url="http://localhost:5984"; \
		test -x /opt/couchdb/scripts/init-seed-data.sh; \
		databases=$$(curl -fsS --max-time 30 -u "$$auth" "$$url/_all_dbs"); \
		database_paths=$$(printf "%s" "$$databases" | python3 -c "import json, sys, urllib.parse; print(*[urllib.parse.quote(name, safe=str()) for name in json.load(sys.stdin)], sep=chr(10))"); \
		rm -f /opt/couchdb/data/.seed_initialized; \
		for database in $$database_paths; do \
			curl -fsS --max-time 30 -u "$$auth" -X DELETE "$$url/$$database" >/dev/null; \
			curl -fsS --max-time 30 -u "$$auth" -X PUT "$$url/$$database" >/dev/null; \
		done; \
		/opt/couchdb/scripts/init-seed-data.sh; \
		test -f /opt/couchdb/data/.seed_initialized; \
	'; \
	if [ "$$paused" = "1" ]; then \
		$(COMPOSE) unpause yggdrasil; \
		trap - 0 INT TERM; \
	fi; \
	echo "StatusDB reset and seeded. Yggdrasil restored to its previous state; files and other services were left untouched."

compose-reset-work: ## Clear Yggdrasil's /work volume while it is paused (CONFIRM=1)
	@if [ "$(CONFIRM)" != "1" ]; then \
		echo "ERROR: This deletes all Yggdrasil /work contents, including cached results; rerun with CONFIRM=1"; \
		exit 1; \
	fi
	@set -eu; \
	ygg_container=$$($(COMPOSE) ps -q yggdrasil); \
	if [ -z "$$ygg_container" ]; then echo "ERROR: Yggdrasil must be running"; exit 1; fi; \
	work_volume=$$(docker inspect --format '{{range .Mounts}}{{if and (eq .Destination "/work") (eq .Type "volume")}}{{.Name}}{{end}}{{end}}' "$$ygg_container"); \
	if [ -z "$$work_volume" ]; then echo "ERROR: No named volume mounted at /work; refusing to delete files"; exit 1; fi; \
	image=$$(docker inspect --format '{{.Image}}' "$$ygg_container"); \
	ygg_state=$$(docker inspect --format '{{.State.Running}} {{.State.Paused}}' "$$ygg_container"); \
	paused=0; \
	case "$$ygg_state" in \
		"true false") \
			$(COMPOSE) pause yggdrasil; \
			paused=1; \
			trap '$(COMPOSE) unpause yggdrasil' 0; \
			trap 'exit 130' INT; \
			trap 'exit 143' TERM ;; \
		"true true") ;; \
		*) echo "ERROR: Yggdrasil must be running"; exit 1 ;; \
	esac; \
	docker run --rm --network none --user 0 \
		--mount "type=volume,source=$$work_volume,target=/work" \
		--entrypoint /bin/sh "$$image" -ec 'find /work -xdev -mindepth 1 -delete'; \
	if [ "$$paused" = "1" ]; then \
		$(COMPOSE) unpause yggdrasil; \
		trap - 0 INT TERM; \
	fi; \
	echo "Yggdrasil /work cleared; previous pause state restored. Databases, events, and logs were left untouched."

compose-trigger-rerun: ## Increment run_token on all non-system documents in yggdrasil_plans
	@set -eu; \
	documents=$$(curl -fsS --max-time 30 \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		'http://localhost:5984/yggdrasil_plans/_all_docs?include_docs=true'); \
	body=$$(printf '%s' "$$documents" | python3 -c 'import json, sys; docs = [row["doc"] for row in json.load(sys.stdin)["rows"] if not row["id"].startswith("_")]; assert all(type(doc.get("run_token", 0)) is int for doc in docs), "run_token must be an integer; no documents updated"; print(json.dumps({"docs": [dict(doc, run_token=doc.get("run_token", 0) + 1) for doc in docs]}))'); \
	result=$$(printf '%s' "$$body" | curl -fsS --max-time 30 -X POST \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		-H 'Content-Type: application/json' \
		--data-binary @- \
		'http://localhost:5984/yggdrasil_plans/_bulk_docs'); \
	printf '%s' "$$result" | python3 -c 'import json, sys; results = json.load(sys.stdin); errors = [row for row in results if "error" in row]; [print("ERROR: " + json.dumps(row), file=sys.stderr) for row in errors]; print("Incremented run_token on %d plan document(s)." % sum(bool(row.get("ok")) for row in results)); sys.exit(bool(errors))'

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
# Mark a seeded flowcell as fully synced to trigger demux workflow
FLOWCELL_ID ?= A12GGASZR5
compose-sync-flowcell: ## Mark the seeded flowcell as fully synced by adding transferred_to_hpc event
	@file="deploy/seed/flowcell_status/flowcell_status_$${FLOWCELL_ID}.json"; \
	if [ ! -f "$$file" ]; then \
		echo "error: flowcell config file '$$file' not found"; \
		exit 1; \
	fi; \
	id=$$(python3 -c "import json; print(json.load(open('$$file'))['_id'])"); \
	code=$$(curl -s -o /dev/null -w '%{http_code}' \
		-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
		"http://localhost:5984/flowcell_status/$${id}"); \
	if [ "$${code}" = "404" ]; then \
		echo "error: flowcell_status doc '$${id}' not found (HTTP 404) - is the stack up and seeded? try: make compose-up && make compose-seed-status"; \
	else \
		now=$$(date -u +%Y-%m-%dT%H:%M:%SZ); \
		body=$$(curl -s -u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" "http://localhost:5984/flowcell_status/$${id}" | \
			python3 deploy/seed/add_transferred_event.py "$${now}") && \
		curl -sf -X PUT \
			-u "$${STACK_COUCH_USER:-admin}:$${STACK_COUCH_PASSWORD:-secret}" \
			-H 'Content-Type: application/json' \
			--data-binary "$${body}" \
			"http://localhost:5984/flowcell_status/$${id}" >/dev/null && \
		echo "Finalized flowcell doc '$${id}' (added transferred_to_hpc event at $${now}) for flowcell $${FLOWCELL_ID}"; \
	fi
	@echo "Watch the workflow with: make compose-logs"