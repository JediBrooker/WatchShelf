# WatchShelf - Connect IQ build, CLI only (no editor / no VS Code).
#   make build              -> bin/WatchShelf.prg for the Tactix 8 (fenix847mm)
#   make build DEVICE=venu3 -> build for another device
#   make sim                -> build + launch the simulator and load the app
#   make package            -> bin/WatchShelf.iq for the Connect IQ Store (all devices)
#   make key                -> generate the developer signing key
#   make devices            -> list installed device ids
#   make clean

DEVICE ?= fenix847mm
APP    := WatchShelf
KEY    ?= developer_key.der
JUNGLE := monkey.jungle
BIN    := bin

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

.PHONY: all build sim package key devices clean

all: build

# One-time signing key (reuse the SAME key forever, or installs won't update).
$(KEY):
	openssl genrsa -out developer_key.pem 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out $(KEY) -nocrypt
key: $(KEY)

# Debug build for one device.
build: $(KEY)
	@mkdir -p $(BIN)
	"$(MONKEYC)" -d $(DEVICE) -f $(JUNGLE) -o $(BIN)/$(APP).prg -y $(KEY) -w
	@echo "built $(BIN)/$(APP).prg for $(DEVICE)"

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
