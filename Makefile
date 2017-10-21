#
# makefile for HA script distro
# $Id: Makefile 3.26 2017-10-21 00:44:18 rob.navarro $
#
# Copyright 2016 AppDynamics, Inc
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

SHELL=/bin/bash

BASH_SRC= assassin.sh failover.sh watchdog.sh \
	watchdog.settings.template \
	replicate.sh install-init.sh uninstall-init.sh \
	appdservice-pbrun.sh appdservice-root.sh appdservice-noroot.sh \
	appdservice-xuser.sh appdstatus.sh \
	appdynamics-machine-agent.sh \
	mysqlclient.sh getaccess.sh setmonitor.sh \
	appdcontroller.sh appdcontroller-db.sh \
	appdynamics-machine-agent.sysconfig.template \
	appdcontroller.sysconfig.template \
	appdcontroller-db.sysconfig.template \
	numa.settings.template numa-patch-controller.sh \
	userid-patch-controller.sh check_for_root_files.sh \
	save_mysql_passwd.sh rsyncd.conf

BASH_LIBS= lib/password.sh lib/ha.sh lib/sql.sh lib/log.sh lib/conf.sh \
	lib/runuser.sh lib/init.sh lib/status.sh

C_SRC= appdservice.c

DIRS= lib monitors monitors/DiskMonitor monitors/MysqlMonitor

MONITORS= \
	monitors/DiskMonitor/monitor.xml monitors/DiskMonitor/disk-stat.sh \
	monitors/MysqlMonitor/monitor.xml monitors/MysqlMonitor/mysql-stat.sh \
	monitors/DiskMonitor/README monitors/MysqlMonitor/README

NOT_EMBEDDED= VERSION README.txt RUNBOOK UPGRADING Release_Notes $(C_SRC)

BASH_SRC_EMBEDDED := $(addprefix build/,$(BASH_SRC))

SOURCES= $(NOT_EMBEDDED) $(BASH_SRC_EMBEDDED) $(addprefix build/,$(BASH_LIBS))

all: HA.shar

HA.shar: build $(SOURCES) Makefile
	date +"# HA package version `cat VERSION` built %c" > HA.shar
	echo "if echo '" >> HA.shar
	echo "' | od -b | grep -q 015 ; then echo dos format script - exiting ; exit 0 ; fi ; true" >> HA.shar
	echo 'if [ $$(basename $$(pwd -P)) != HA ] ; then' >> HA.shar
	echo 'mkdir -p HA ; if ! [ -d HA ] ; then echo "no HA directory" ; exit 0 ; fi; echo cd to HA ; cd HA; fi' >> HA.shar
	echo "echo unpacking HA version `cat VERSION`" >> HA.shar
	cd build && shar $(NOT_EMBEDDED) $(DIRS) $(MONITORS) $(BASH_SRC) $(BASH_LIBS) >> ../HA.shar
	rm -f HA.shar.tmp ; mv HA.shar HA.shar.tmp
	sed 's/^exit/chmod ugo+rx . .. ; find . -name \\*.sh -print | xargs chmod ugo+rx; exit/' < HA.shar.tmp >HA.shar
	rm HA.shar.tmp

$(BASH_SRC_EMBEDDED): $(BASH_SRC) $(BASH_LIBS)
	perl tools/embed.pl $(notdir $@) > $@

$(addprefix build/,$(BASH_LIBS)): $(BASH_LIBS)
	cp lib/$(notdir $@) $@

build: $(NOT_EMBEDDED)
	mkdir -p build
	(cd build ; mkdir -p $(DIRS))
	cp -r $(NOT_EMBEDDED) monitors build

# useful debug aid. View variables on cmd line with:
#  make V="SOURCES BASH_SRC_EMBEDDED" debug
debug:
	$(foreach v,$(V),$(warning $v = $($v)))

# useful debug aid. View variables on cmd line with:
#  make print-SOURCES print-BASH_SRC_EMBEDDED
print-%:
	@echo '$*=$($*)'

#
# some common targets
#

clean:
	rm -f appdservice HA.shar.tmp
	rm -rf build

clobber: clean
	rm -f HA.shar

install: HA.shar
	@if [ -f INSTALLTARGETS ] ; then \
		for target in `cat INSTALLTARGETS` ; do \
			echo copying to $$target ; \
			scp -q HA.shar $$target & \
		done ; \
		wait ; \
	fi

#
# not used normally, as the install-init.sh compiles it in an installation
# here for development purposes.
#
appdservice: appdservice.c
	cc -DAPPDUSER=`id -u` -o appdservice appdservice.c
