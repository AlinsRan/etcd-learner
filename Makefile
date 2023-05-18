# Makefile basic env setting
.DEFAULT_GOAL := help

# Makefile SHELL setting
## SHELL_ARGS used for extra shell flag
## add flag to fetch error info for default shell
SHELL_ARGS ?=
SHELL      := /bin/bash -uo pipefail $(SHELL_ARGS)


# Project basic setting
project_name            ?= project_ha_etcd_cluster
project_version         ?= 0.0.4
project_launch_utc      ?= $(shell date +%Y%m%d%H%M%S)
project_logrotate       ?= /etc/logrotate.d/$(project_name)
project_service         ?= $(project_name).service
project_timer           ?= $(project_name).timer
project_systemd_service ?= /usr/lib/systemd/system/$(project_service)
project_systemd_timer   ?= /usr/lib/systemd/system/$(project_timer)
project_backup_type     ?= manualy
project_compose         ?= pod/docker-compose.yaml
project_release_folder  ?= release
project_release_name    ?= $(project_release_folder)/$(project_name)_release.v$(project_version).$(project_launch_utc).tar.gz


# Hyper-converged Infrastructure
ENV_COMMAND_V        ?= command -v
ENV_DOCKER_COMPOSE   ?= $(shell $(ENV_COMMAND_V) docker-compose) -p $(project_name) --project-directory $(CURDIR) -f $(project_compose)
ENV_LOGROTATE        ?= $(shell $(ENV_COMMAND_V) logrotate)
ENV_MAKE             ?= $(shell $(ENV_COMMAND_V) make)
ENV_MAKEFILE         ?= Makefile
ENV_HELP_PREFIX_SIZE ?= 20
ENV_SHASUM           ?= $(shell $(ENV_COMMAND_V) shasum) -a 512
ENV_SYSTEMCTL        ?= $(shell $(ENV_COMMAND_V) systemctl)
ENV_TAR              ?= $(shell $(ENV_COMMAND_V) tar)


# AWK patch for mawk
ifneq ($(shell $(ENV_COMMAND_V) gawk),)
	ENV_HELP_AWK_RULE ?= '{ if(match($$0, /^\s*\#{3}\s*([^:]+)\s*:\s*(.*)$$/, res)){ printf("    make %-$(ENV_HELP_PREFIX_SIZE)s : %-10s\n", res[1], res[2]) } }'
else
	ENV_HELP_AWK_RULE := '{ if(match($$0, /^\#\#\#([^:]+):(.*)$$/)){ split($$0, res, ":"); gsub(/^\#\#\#[ ]*/, "", res[1]); _desc=$$0; gsub(/^\#\#\#([^:]+):[ \t]*/, "", _desc); printf("    make %-$(ENV_HELP_PREFIX_SIZE)s : %-10s\n", res[1], _desc) } }'
endif

# ENV patch for darwin
ifeq ($(ENV_OS_NAME), darwin)
	ENV_HELP_AWK_RULE := '{ if(match($$0, /^\#{3}([^:]+):(.*)$$/)){ split($$0, res, ":"); gsub(/^\#{3}[ ]*/, "", res[1]); _desc=$$0; gsub(/^\#{3}([^:]+):[ \t]*/, "", _desc); printf("    make %-$(ENV_HELP_PREFIX_SIZE)s : %-10s\n", res[1], _desc) } }'
	# OSX archive `._` cache file
	ENV_TAR := COPYFILE_DISABLE=1 $(ENV_TAR)
endif


# Makefile basic extension function
_color_red    =\E[1;31m
_color_green  =\E[1;32m
_color_yellow =\E[1;33m
_color_blue   =\E[1;34m
_color_wipe   =\E[0m
_echo_format  ="[%b info %b] %s\n"


define func_echo_status
	printf $(_echo_format) "$(_color_blue)" "$(_color_wipe)" $(1)
endef


define func_echo_warn_status
	printf $(_echo_format) "$(_color_yellow)" "$(_color_wipe)" $(1)
endef


define func_echo_success_status
	printf $(_echo_format) "$(_color_green)" "$(_color_wipe)" $(1)
endef


define func_echo_error_status
	printf $(_echo_format) "$(_color_red)" "$(_color_wipe)" $(1)
endef


# etcd cluster configure
-include .etcd
export

# etcd backup rotate configure
project_backup_folder          ?= $(ENV_ETCD_DATA_FOLDER)/backup
project_snapshot_folder        ?= $(ENV_ETCD_DATA_FOLDER)/snapshot
project_logrotate_size_hourly  ?= 24
project_logrotate_size_daily   ?= 30


# Makefile backup extension function
### function for etcd container snapshot backup
### $(1) container name
### $(2) etcd auth args
### $(3) etcd snapshot backup prefix
define pod_etcd_backup
	$(ENV_DOCKER_COMPOSE) exec -T $(1) bash -c "etcdctl snapshot save /bitnami/etcd/snapshot/$(3)_$(project_name).bak"
endef


# Makefile target

### pod-permission-init : Init pod env
.PHONY: pod-permission-init
pod-permission-init:
	@$(call func_echo_status, "$@ -> [ Start ]")
	@mkdir -p $(ENV_ETCD_DATA_FOLDER)/{certs,data,snapshot,restore}
	@chown 1001:1001 -R $(ENV_ETCD_DATA_FOLDER)
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### pod-config : Check final docker-compose yaml
.PHONY: pod-config
pod-config:
	@$(call func_echo_status, "$@ -> [ Start ]")
	@$(ENV_DOCKER_COMPOSE) config
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### pod-up : Launch docker-compose service
.PHONY: pod-up
pod-up: pod-permission-init
	@$(call func_echo_status, "$@ -> [ Start ]")
	@$(ENV_DOCKER_COMPOSE) up -d
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### pod-down : Shutdown docker-compose service
.PHONY: pod-down
pod-down:
	@$(call func_echo_status, "$@ -> [ Start ]")
	@$(ENV_DOCKER_COMPOSE) down
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### etcd-compact : Compact etcd reversion
.PHONY: etcd-compact
etcd-compact:
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(eval ENV_ETCD_RAFT_VER := $(shell $(ENV_DOCKER_COMPOSE) exec etcd bash -c "etcdctl $(ENV_ETCD_AUTH) endpoint status -w fields" | grep "Revision" | awk 'BEGIN{FS=": "} { print $$2 }'))
	$(eval ENV_ETCD_RAFT_NEW_VER := $(shell expr $(ENV_ETCD_RAFT_VER) - $(ETCD_REVERSION_SIZE)))
	@-$(ENV_DOCKER_COMPOSE) exec etcd bash -c "etcdctl $(ENV_ETCD_CLUSTER_ENDPOINTS) $(ENV_ETCD_AUTH) compact $(ENV_ETCD_RAFT_NEW_VER)"
	@-$(ENV_DOCKER_COMPOSE) exec etcd bash -c "etcdctl $(ENV_ETCD_CLUSTER_ENDPOINTS) $(ENV_ETCD_AUTH) defrag"
	@$(call func_echo_success_status, "$@ -> [ Done ]")


# etcd OP
### etcd-backup : backup etcd snapshot
.PHONY: etcd-backup
etcd-backup: pod-permission-init
	@$(call func_echo_status, "$@ -> [ Start ]")
	@$(call pod_etcd_backup,etcd,$(ENV_ETCD_CLUSTER_MEMBERS) $(ENV_ETCD_AUTH),$(project_backup_type))
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### etcd-backup-rotate : Install backup rotate
.PHONY: etcd-backup-rotate
etcd-backup-rotate: pod-permission-init
	@$(call pod_etcd_backup,etcd,$(ENV_ETCD_CLUSTER_MEMBERS) $(ENV_ETCD_AUTH),hourly)
	@$(call pod_etcd_backup,etcd,$(ENV_ETCD_CLUSTER_MEMBERS) $(ENV_ETCD_AUTH),daily)
	@# backup rotate
	@echo "$(project_snapshot_folder)/hourly_*.bak {"                                  > $(project_logrotate)
	@echo "    hourly"                                                                >> $(project_logrotate)
	@echo "    copy"                                                                  >> $(project_logrotate)
	@echo "    rotate $(project_logrotate_size_hourly)"                               >> $(project_logrotate)
	@echo "    dateext"                                                               >> $(project_logrotate)
	@echo "    dateformat -%Y-%m-%d-%H"                                               >> $(project_logrotate)
	@echo "    missingok"                                                             >> $(project_logrotate)
	@echo "    nocompress"                                                            >> $(project_logrotate)
	@echo "    create 0644 root root"                                                 >> $(project_logrotate)
	@echo "    olddir $(project_backup_folder)"                                       >> $(project_logrotate)
	@echo "    createolddir 0644 root root"                                           >> $(project_logrotate)
	@echo "    sharedscripts"                                                         >> $(project_logrotate)
	@echo "    prerotate"                                                             >> $(project_logrotate)
	@echo "        $(ENV_MAKE) -C $(CURDIR) etcd-backup project_backup_type=hourly"   >> $(project_logrotate)
	@echo "    endscript"                                                             >> $(project_logrotate)
	@echo "}"                                                                         >> $(project_logrotate)
	@echo "$(project_snapshot_folder)/daily_*.bak {"                                  >> $(project_logrotate)
	@echo "    daily"                                                                 >> $(project_logrotate)
	@echo "    copy"                                                                  >> $(project_logrotate)
	@echo "    rotate $(project_logrotate_size_daily)"                                >> $(project_logrotate)
	@echo "    dateext"                                                               >> $(project_logrotate)
	@echo "    dateformat -%Y-%m-%d"                                                  >> $(project_logrotate)
	@echo "    missingok"                                                             >> $(project_logrotate)
	@echo "    nocompress"                                                            >> $(project_logrotate)
	@echo "    create 0644 root root"                                                 >> $(project_logrotate)
	@echo "    olddir $(project_backup_folder)"                                       >> $(project_logrotate)
	@echo "    createolddir 0644 root root"                                           >> $(project_logrotate)
	@echo "    sharedscripts"                                                         >> $(project_logrotate)
	@echo "    prerotate"                                                             >> $(project_logrotate)
	@echo "        $(ENV_MAKE) -C $(CURDIR) etcd-backup project_backup_type=daily"    >> $(project_logrotate)
	@echo "    endscript"                                                             >> $(project_logrotate)
	@echo "}"                                                                         >> $(project_logrotate)
	@$(call func_echo_status, "$@ -> Generate logrotate service -> [ Done ]")
	@cat $(project_logrotate)

	@echo "[Unit]"                                                                     > $(project_service)
	@echo "Description=etcd backup service defined by $(project_name)"                >> $(project_service)
	@echo "After=network.target remote-fs.target nss-lookup.target"                   >> $(project_service)
	@echo ""                                                                          >> $(project_service)
	@echo "[Service]"                                                                 >> $(project_service)
	@echo "Type=simple"                                                               >> $(project_service)
	@echo "ExecStart=$(ENV_LOGROTATE) -vf $(project_logrotate)"                       >> $(project_service)
	@echo ""                                                                          >> $(project_service)
	@echo "[Install]"                                                                 >> $(project_service)
	@echo "WantedBy=multi-user.target"                                                >> $(project_service)
	@$(call func_echo_success_status, "$@ -> Generate service -> [ Done ]")
	@cat $(project_service)

	@echo "[Unit]"                                                                     > $(project_timer)
	@echo "Description=backup timer defined by $(project_name)"                       >> $(project_timer)
	@echo ""                                                                          >> $(project_timer)
	@echo "[Timer]"                                                                   >> $(project_timer)
	@echo "OnUnitActiveSec=60min"                                                      >> $(project_timer)
	@echo "Unit=$(project_service)"                                                   >> $(project_timer)
	@echo ""                                                                          >> $(project_timer)
	@echo "[Install]"                                                                 >> $(project_timer)
	@echo "WantedBy=multi-user.target"                                                >> $(project_timer)
	@$(call func_echo_success_status, "$@ -> Generate service timer -> [ Done ]")
	@cat $(project_service)

	@$(call func_echo_status, "$@ -> Apply service -> [ Start ]")
	@cp -f $(project_service) $(project_systemd_service)
	@cp -f $(project_timer) $(project_systemd_timer)
	@$(call func_echo_status, "$@ -> Reload service -> [ Start ]")
	@$(ENV_SYSTEMCTL) daemon-reload

	$(ENV_SYSTEMCTL) enable --now $(project_service)
	$(ENV_SYSTEMCTL) enable --now $(project_timer)
	@$(call func_echo_success_status, "$@ -> Auto install service to systemd -> [ Done ]")

### etcd-restore : restore etcd snapshot
.PHONY: etcd-restore
etcd-restore: pod-permission-init
	@$(call func_echo_status, "$@ -> [ Start ]")
	$(ENV_DOCKER_COMPOSE) exec etcd bash -c "etcdctl $(ENV_ETCD_AUTH) snapshot restore /bitnami/etcd/snapshot/target.bak $(ENV_ETCD_RESTORE_CONFIG)"
	@$(call func_echo_success_status, "$@ -> [ Done ]")


### release : Release current project without version control
.PHONY: release
release:
	@$(call func_echo_status, "$@ -> [ Start ]")
	@# cache launch utc
	$(eval project_launch_utc := $(project_launch_utc))
	@if [[ ! -d $(project_release_folder) ]]; then \
		$(call func_echo_status, "create release archive folder -> $(project_release_folder)"); \
		mkdir -p $(project_release_folder); \
	fi
	$(ENV_TAR) -zcv \
		--exclude *.git \
		--exclude *.github \
		--exclude *.idea \
		--exclude *.vagrant \
		--exclude *.editorconfig \
		--exclude *.gitignore \
		--exclude *.DS_Store \
		--exclude *ci \
		--exclude *Vagrantfile \
		--exclude $(project_release_folder) \
		-f $(project_release_name) .
	@$(ENV_SHASUM) $(project_release_name) > $(project_release_name).sha512
	@$(call func_echo_success_status, "$@ -> $(project_release_name) -> [ Done ]")


### help : Show Makefile rules
.PHONY: help
help:
	@$(call func_echo_success_status, "Makefile rules:")
	@echo
	@cat $(ENV_MAKEFILE) | awk $(ENV_HELP_AWK_RULE)
	@echo
