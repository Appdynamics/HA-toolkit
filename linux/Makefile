#
# makefile for HA script distro
# $Id: Makefile,v 2.4 2015/02/11 20:19:23 cmayer Exp cmayer $
#
APPD_ROOT=/opt/AppDynamics/Controller

SOURCES= README Makefile \
	appdcontroller-db.sh appdcontroller.sh \
	assassin.sh failover.sh watchdog.sh \
	install-init.sh uninstall-init.sh \
	watchdog.settings.template \
	replicate.sh install-init.sh uninstall-init.sh

all: HA.shar

source: $(SOURCES)

install:
	rm -f $(APPD_ROOT)/HA/*
	mkdir -p $(APPD_ROOT)/HA
	cp README *.sh $(APPD_ROOT)/HA
	sudo $(APPD_ROOT)/HA/install-init.sh

HA.shar: $(SOURCES)
	date +"# HA package built %c" > HA.shar
	shar $(SOURCES) | sed -e 's/^exit/chmod ugo+rx . .. *.sh; exit/' >> HA.shar
