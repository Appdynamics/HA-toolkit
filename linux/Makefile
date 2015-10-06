#
# makefile for HA script distro
# $Id: Makefile 2.6 2015-06-12 12:22:17 cmayer $
#
APPD_ROOT=/opt/AppDynamics/Controller

SOURCES= README Makefile \
	appdcontroller-db.sh appdcontroller.sh \
	assassin.sh failover.sh watchdog.sh \
	install-init.sh uninstall-init.sh \
	watchdog.settings.template \
	replicate.sh install-init.sh uninstall-init.sh \
	appdservice.c appdservice.sh hafunctions.sh RUNBOOK

all: HA.shar

source: $(SOURCES)

install:
	rm -f $(APPD_ROOT)/HA/*
	mkdir -p $(APPD_ROOT)/HA
	cp README *.sh $(APPD_ROOT)/HA
	sudo $(APPD_ROOT)/HA/install-init.sh

HA.shar: $(SOURCES) Makefile
	date +"# HA package built %c" > HA.shar
	echo "if echo '" >> HA.shar
	echo "' | od -b | grep -q 015 ; then echo dos format script - exiting ; exit 0 ; fi ; true" >> HA.shar
	shar $(SOURCES) | sed -e 's/^exit/chmod ugo+rx . .. *.sh; exit/' >> HA.shar

#
# not used normally, as the install-init.sh compiles it in an installation
# here for development purposes.
#
appdservice: appdservice.c
	cc -DAPPDUSER=`id -u` -o appdservice appdservice.c
