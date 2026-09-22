# WatchShelf - Connect IQ build, CLI only (no editor / no VS Code).
#   make build              -> bin/WatchShelf.prg for the Tactix 8 (fenix847mm)
#   make build DEVICE=venu3 -> build for another device
#   make sim                -> build + launch the simulator and load the app
#   make package            -> bin/WatchShelf.iq for the Connect IQ Store (all devices)
#   make key                -> generate the developer signing key
#   make devices            -> list installed device ids
#   make clean

DEVICE ?= fenix8solar51mm
APP    := WatchShelf
KEY    ?= developer_key.der
JUNGLE := monkey.jungle
BIN    := bin
SYMS   := debug-symbols

# Visible build tag (Versions.tag), used to name the archived symbol file.
TAG    := $(shell sed -n 's/.*tag = "\([^"]*\)".*/\1/p' source/Constants.mc)

# The Connect IQ SDK needs Java on PATH. This is where the Homebrew JDK lives on
# this machine; adjust if yours differs (`java -version` must work).
export PATH := /opt/homebrew/opt/openjdk@17/bin:$(PATH)

# Resolve the active SDK bin/ from the SDK Manager's own config (version-proof).
CIQ_HOME := $(HOME)/Library/Application Support/Garmin/ConnectIQ
SDK_DIR  := $(shell cat "$(CIQ_HOME)/current-sdk.cfg" 2>/dev/null)
SDK_BIN  := $(SDK_DIR)bin
MONKEYC  := $(SDK_BIN)/monkeyc
MONKEYDO := $(SDK_BIN)/monkeydo
SIM      := $(SDK_BIN)/connectiq

.PHONY: all build sim package key devices symbols clean

all: build

# One-time signing key (reuse the SAME key forever, or installs won't update).
$(KEY):
	openssl genrsa -out developer_key.pem 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out $(KEY) -nocrypt
key: $(KEY)

# Debug build for one device. Archives this build's symbols on the way out -
# see the `symbols` target for why that must not be a manual step.
build: $(KEY)
	@mkdir -p $(BIN)
	"$(MONKEYC)" -d $(DEVICE) -f $(JUNGLE) -o $(BIN)/$(APP).prg -y $(KEY) -w
	@$(MAKE) --no-print-directory symbols || \
		echo "WARNING: debug symbols NOT archived - a crash log from this build will not decode"
	@echo "built $(BIN)/$(APP).prg for $(DEVICE)"

# Copy this build's debug symbols to debug-symbols/<tag>-<device>.debug.xml.
# <tag> is Versions.tag in source/Constants.mc.
#
# The DEVICE is part of the name because program counters are per-device: the
# same source built for vivoactive4 and for fr965 puts `deleteBook` at
# 268447414 and 268444875 respectively. Decoding a log against the wrong
# device's symbols yields plausible, WRONG file:line - worse than no answer.
#
# A CIQ_LOG.YML off a user's watch decodes ONLY against the exact symbol file
# of the build that produced it - so every build that reaches a watch needs its
# symbols committed alongside it. Doing that by hand lapsed after b28 while
# shipped builds went on to b35, which is why the crash reports on issue #53
# could not be read at all. Hence: automatic, on every build.
symbols:
	@test -n "$(TAG)" || { echo "cannot read Versions.tag from source/Constants.mc"; exit 1; }
	@test -f "$(BIN)/$(APP).prg.debug.xml" || { echo "no $(BIN)/$(APP).prg.debug.xml - run 'make build' first"; exit 1; }
	@mkdir -p $(SYMS)
	@cp "$(BIN)/$(APP).prg.debug.xml" "$(SYMS)/$(TAG)-$(DEVICE).debug.xml"
	@echo "archived $(SYMS)/$(TAG)-$(DEVICE).debug.xml - COMMIT IT with the build"
	@# If a tag named after Versions.tag already exists, this build must BE it.
	@# Building later source while the tag still says $(TAG) produces a file
	@# labelled $(TAG) whose addresses do not match the released binary - it
	@# decodes crash logs to confident, WRONG lines. Measured once: 515 of 1607
	@# shared entries moved between the b37 tag and two commits after it.
	@if git rev-parse --git-dir >/dev/null 2>&1 && \
	    git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null 2>&1 && \
	    [ "$$(git rev-parse HEAD)" != "$$(git rev-parse "$(TAG)^{commit}")" ]; then \
	  echo ""; \
	  echo "  WARNING: tag $(TAG) exists but HEAD is NOT that commit."; \
	  echo "  These symbols are labelled $(TAG) yet were built from different"; \
	  echo "  source, so they will mis-decode crash logs from the released"; \
	  echo "  $(TAG) build. Either bump Versions.tag, or build from the tag:"; \
	  echo "      git checkout $(TAG) && make build DEVICE=$(DEVICE)"; \
	  echo ""; \
	fi

# Build then launch the simulator (leave the sim window open).
sim: build
	@echo "launching Connect IQ simulator..."
	@"$(SIM)" & sleep 3
	"$(MONKEYDO)" $(BIN)/$(APP).prg $(DEVICE)

# Store-ready package for EVERY device in manifest.xml (all bundles must be
# installed via the SDK Manager first).
package: $(KEY)
	@mkdir -p $(BIN)
	"$(MONKEYC)" -f $(JUNGLE) -o $(BIN)/$(APP).iq -y $(KEY) -e -r -w
	@echo "packaged $(BIN)/$(APP).iq"

devices:
	@ls "$(CIQ_HOME)/Devices" | sort

clean:
	rm -rf $(BIN) gen
