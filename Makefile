PREFIX ?= /opt/wgctl
BIN_DIR ?= /usr/local/bin
INSTALL ?= install
OWNER ?= root
GROUP ?= root
DIR_MODE ?= 0755
DATA_DIR_MODE ?= 0750
SCRIPT_MODE ?= 0755
CONFIG_MODE ?= 0640

SCRIPT_NAME := wgctl.sh
SCRIPT_TARGET := $(PREFIX)/wgctl.sh
CONFIG_DIR := $(PREFIX)/config
DATA_DIR := $(PREFIX)/data
CONFIG_EXAMPLE := $(CONFIG_DIR)/wgctl.conf.example
CONFIG_FILE := $(CONFIG_DIR)/wgctl.conf
SYMLINK_TARGET := $(BIN_DIR)/wgctl

.PHONY: help install uninstall deps deps-debian deps-dnf deps-yum deps-pacman deps-zypper

help:
	@printf '%s\n' \
		'Targets:' \
		'  make install      Install wgctl into $(PREFIX) and create $(SYMLINK_TARGET)' \
		'  make uninstall    Remove installed files and symlink' \
		'  make deps         Install dependencies using the detected package manager' \
		'  make deps-debian  Install dependencies with apt/apt-get' \
		'  make deps-dnf     Install dependencies with dnf' \
		'  make deps-yum     Install dependencies with yum' \
		'  make deps-pacman  Install dependencies with pacman' \
		'  make deps-zypper  Install dependencies with zypper' \
		'' \
		'Install variables:' \
		'  PREFIX=/opt/wgctl' \
		'  BIN_DIR=/usr/local/bin' \
		'  OWNER=root GROUP=root' \
		'  DIR_MODE=0755 DATA_DIR_MODE=0750' \
		'  SCRIPT_MODE=0755 CONFIG_MODE=0640'

install:
	$(INSTALL) -d -m "$(DIR_MODE)" -o "$(OWNER)" -g "$(GROUP)" "$(PREFIX)" "$(CONFIG_DIR)" "$(BIN_DIR)"
	$(INSTALL) -d -m "$(DATA_DIR_MODE)" -o "$(OWNER)" -g "$(GROUP)" "$(DATA_DIR)"
	$(INSTALL) -m "$(SCRIPT_MODE)" -o "$(OWNER)" -g "$(GROUP)" "$(SCRIPT_NAME)" "$(SCRIPT_TARGET)"
	$(INSTALL) -m "$(CONFIG_MODE)" -o "$(OWNER)" -g "$(GROUP)" "config/wgctl.conf.example" "$(CONFIG_EXAMPLE)"
	@if [ ! -f "$(CONFIG_FILE)" ]; then \
		$(INSTALL) -m "$(CONFIG_MODE)" -o "$(OWNER)" -g "$(GROUP)" "config/wgctl.conf.example" "$(CONFIG_FILE)"; \
	fi
	ln -snf "$(SCRIPT_TARGET)" "$(SYMLINK_TARGET)"

uninstall:
	rm -f "$(SYMLINK_TARGET)"
	rm -f "$(SCRIPT_TARGET)"
	rm -f "$(CONFIG_EXAMPLE)"
	@printf '%s\n' 'Installed config and data were kept intact:' "$(CONFIG_FILE)" "$(DATA_DIR)"

deps:
	@if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then \
		$(MAKE) deps-debian; \
	elif command -v dnf >/dev/null 2>&1; then \
		$(MAKE) deps-dnf; \
	elif command -v yum >/dev/null 2>&1; then \
		$(MAKE) deps-yum; \
	elif command -v pacman >/dev/null 2>&1; then \
		$(MAKE) deps-pacman; \
	elif command -v zypper >/dev/null 2>&1; then \
		$(MAKE) deps-zypper; \
	else \
		printf '%s\n' 'Unsupported package manager. Install these packages manually: wireguard-tools qrencode mailutils'; \
		exit 1; \
	fi

deps-debian:
	sudo apt-get update
	sudo apt-get install -y wireguard-tools qrencode mailutils

deps-dnf:
	sudo dnf install -y wireguard-tools qrencode mailx

deps-yum:
	sudo yum install -y epel-release
	sudo yum install -y wireguard-tools qrencode mailx

deps-pacman:
	sudo pacman -Sy --needed wireguard-tools qrencode mailutils

deps-zypper:
	sudo zypper install -y wireguard-tools qrencode mailx
