# Makefile for relay mode only
# Direct and sodo modes use pure shell scripts

BINARY_DIR := bin

.PHONY: all build-relay clean

all: build-relay

build-relay:
	@mkdir -p $(BINARY_DIR)
	@echo "Building relay mode binaries..."
	cd relay && go build -o ../$(BINARY_DIR)/nmux ./cmd/nmux
	cd relay && go build -o ../$(BINARY_DIR)/nmuxd ./cmd/nmuxd
	@echo "Built: $(BINARY_DIR)/nmux $(BINARY_DIR)/nmuxd"

clean:
	rm -rf $(BINARY_DIR)
