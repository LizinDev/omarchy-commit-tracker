PLUGIN_ID := io.github.lizindev.commit-tracker
DEST      := $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)
# How to run uv's tool runner; on a mise setup without a global uv, use e.g.
# `make lint UVX="mise x uv -- uvx"`.
UVX       ?= uvx

.PHONY: check test lint lint-python lint-shell lint-qml validate install dev

## check: everything CI runs, plus the QML lint and the Omarchy manifest check
check: lint test validate

## test: unit tests (synthetic repositories only)
test:
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests

## lint: Python, shell and QML
lint: lint-python lint-shell lint-qml

lint-python:
	$(UVX) ruff check .

lint-shell:
	$(UVX) --from shellcheck-py shellcheck tools/lint-qml

lint-qml:
	tools/lint-qml

## validate: the Omarchy plugin manifest schema
validate:
	omarchy plugin validate .

## install: copy the plugin into Omarchy's plugin folder (a real copy: the
## validator rejects symlinks inside a plugin)
install:
	rsync -a --delete --exclude .git --exclude .github --exclude .agents --exclude .claude \
	  --exclude tests --exclude tools --exclude __pycache__ --exclude Makefile --exclude pyproject.toml \
	  ./ $(DEST)/

## dev: install and restart the shell (QML changes need a restart)
dev: install
	omarchy restart shell
