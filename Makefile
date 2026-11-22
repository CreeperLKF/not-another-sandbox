BINARY_DIR := bin
CMD_DIR := cmd

.PHONY: all build clean install test

all: build

build: build-setup build-nmux build-nmuxd

build-setup:
	@mkdir -p $(BINARY_DIR)
	go build -o $(BINARY_DIR)/nas-setup ./$(CMD_DIR)/nas-setup

build-nmux:
	@mkdir -p $(BINARY_DIR)
	go build -o $(BINARY_DIR)/nmux ./$(CMD_DIR)/nmux

build-nmuxd:
	@mkdir -p $(BINARY_DIR)
	go build -o $(BINARY_DIR)/nmuxd ./$(CMD_DIR)/nmuxd

install: build
	sudo install -m 755 $(BINARY_DIR)/nmux /usr/local/bin/
	sudo install -m 755 $(BINARY_DIR)/nmuxd /usr/local/bin/
	sudo install -m 755 $(BINARY_DIR)/nas-setup /usr/local/bin/

clean:
	rm -rf $(BINARY_DIR)

test:
	go test -v ./...
