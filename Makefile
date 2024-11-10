TOOLS_BIN_DIR ?= $(shell pwd)/tmp/bin
export PATH := $(TOOLS_BIN_DIR):$(PATH)

SHELLCHECK_BINARY=$(TOOLS_BIN_DIR)/shellcheck
TOOLING=$(SHELLCHECK_BINARY)

.PHONY: shellcheck
shellcheck: $(SHELLCHECK_BINARY)
	$(SHELLCHECK_BINARY) $(shell find . -type f -name "*.sh" -not -path "*/vendor/*")

############
# Binaries #
############

$(TOOLS_BIN_DIR):
	mkdir -p $(TOOLS_BIN_DIR)

$(TOOLING): $(TOOLS_BIN_DIR)
	@echo Downloading shellcheck
	@cd $(TOOLS_BIN_DIR) && wget -qO- "https://github.com/koalaman/shellcheck/releases/download/stable/shellcheck-stable.linux.x86_64.tar.xz" | tar -xJv --strip=1 shellcheck-stable/shellcheck
