#!/bin/bash
### BEGIN INIT INFO
# Provides:          appdcontroller
# Required-Start:    $remote_fs $syslog appdcontroller-db
# Required-Stop:     $remote_fs $syslog appdcontroller-db
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: AppDynamics Controller
# Description:       This script starts and stops the AppDynamics Controller
#                    Database, appserver, and HA components.
### END INIT INFO
#
# $Id: appdcontroller.sh 3.14 2017-03-15 13:03:13 cmayer $
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
#
# HA Aware Init file for AppDynamics Controller 
# 
# chkconfig: 2345 60 25 
# description: Controller for AppDynamics
#
# assumes that the appdynamics controller and database run as the user 
# specified in the db.cnf file
#
# edit this manually if it hasn't been automatically set by the install-init.sh
# script
#

# Setting PATH to just a few trusted directories is an **important security** requirement
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

NAME=$(basename $(readlink -e $0))

APPD_ROOT=/opt/AppDynamics/Controller
RUNUSER=root

# source script config
[ -f /etc/sysconfig/appdcontroller ] && . /etc/sysconfig/appdcontroller
[ -f /etc/default/appdcontroller ] && . /etc/default/appdcontroller

if [ -f $APPD_ROOT/HA/INITDEBUG ] ; then
	logfile=/tmp/$NAME.out
	rm -f $logfile
	exec 2> $logfile
	chown $RUNUSER $logfile
	set -x
fi

OPEN_FD_LIMIT=65536

# For security reasons, locally embed/include function library at HA.shar build time
embed lib/password.sh
embed lib/init.sh
embed lib/conf.sh
embed lib/status.sh

check_sanity

if [ -f "$APPD_ROOT/HA/LARGE_PAGES_ENABLE" ] ; then
	ENABLE_HUGE_PAGES="true"
fi

case "$1" in
start)  
	require_root
	if runuser [ -f $APPSERVER_DISABLE ] ; then
		echo appdcontroller disabled - incomplete replica:w
		exit 1
	fi
	service appdcontroller-db start
	if [[ `id -u $RUNUSER` != "0" ]] && use_privileged_ports ; then
		#trying to bind java to a privilged port as an unpriviliged user
		setcap cap_net_bind_service=+ep "$APPD_ROOT/jre/bin/java"
		echo "$APPD_ROOT/jre/lib/$(uname -m | sed -e 's/x86_64/amd64/')/jli" > \
			/etc/ld.so.conf.d/appdynamics.conf
		ldconfig            
	fi
	if [ "`controller_mode`" == "active" ] ; then
		bg_runuser $CONTROLLER_SH start-appserver >/dev/null
		if replication_disabled ; then
			if assassin_running ; then
				echo assassin already running
			else
				echo starting assassin 
				bg_runuser "$APPD_ROOT/HA/assassin.sh" >/dev/null
			fi
		fi
	# if the events service directory exists, do events stuff.
	# an full scale HA should rename this directory
		if runuser [ -d "$APPD_ROOT/events_service" ] ; then
			if ! events_running ; then
				bg_runuser $CONTROLLER_SH start-events-service >/dev/null
			fi
		fi
		if runuser [ -d "$APPD_ROOT/reporting_service" ] ; then
			if ! reporting_running ; then
				bg_runuser HOME=~$RUNUSER $CONTROLLER_SH start-reporting-service >/dev/null
			fi
		fi
	else
		if replication_disabled ; then
			echo passive node - appd replication disabled
			exit 1
		fi
		echo skipping appserver start - HA passive
		if runuser [ -f $WATCHDOG_ENABLE ] ; then
			if watchdog_running ; then
				echo appd watchdog already running 
			else
				echo starting appd watchdog
				bg_runuser "$APPD_ROOT/HA/watchdog.sh" >/dev/null
				pid=$!
				# wait for the pidfile to be created or the process to die
				while [ -d /proc/$pid ] ; do
					if [ -f $WATCHDOG_PIDFILE ] ; then
						break
					fi
					sleep 1
				done
			fi
		else
			echo watchdog disabled
		fi
	fi
	rm -f $lockfile	
	touch $lockfile	
;;  
  
stop)
	require_root
	if watchdog_running ; then
		kill -9 $watchdog_pid && ( echo appd watchdog killed; \
			runuser "echo `date` appd watchdog killed \ 
				>> $APPD_ROOT/logs/watchdog.log" )
	fi
	runuser rm -f $WATCHDOG_PIDFILE
	if assassin_running ; then
		kill -9 $assassin_pid && ( echo appd assassin killed; \
		runuser "echo `date` appd assassin killed \
			>> $APPD_ROOT/logs/assassin.log" )		
	fi
	runuser rm -f $ASSASSIN_PIDFILE
	# if the events service directory exists, do events stuff.
	# an full scale HA should rename this directory
	if runuser [ -d "$APPD_ROOT/events_service" ] ; then
		runuser $CONTROLLER_SH stop-events-service
	fi
	if runuser [ -d "$APPD_ROOT/reporting_service" ] ; then
		runuser HOME=~$RUNUSER $CONTROLLER_SH stop-reporting-service
	fi
	# The default controller shutdown timeout is 45 minutes 
	# That is a long time to be stuck with a hung appserver on the way down.
	# Thankfully, we can set an environment variable to override that:
	export AD_SHUTDOWN_TIMEOUT_IN_MIN=10
    runuser $CONTROLLER_SH stop-appserver
	controllerrunning
	if [ $? -lt 3 ] ; then
		echo "forcibly killing appserver"
		pkill -9 -f "$APPD_ROOT/appserver/glassfish/domains/domain1"
		echo "truncate ejb__timer__tbl;" | runuser $MYSQLCLIENT 
	fi
	#
	# an interesting case is if we are the active node, and replication is up,
	# and HA/SHUTDOWN_FAILOVER exists, we will make tell the secondary to start
	# an appserver
	#
	if [ -f $SHUTDOWN_FAILOVER -a "`controller_mode`" == active ] ; then
		secondary=`echo "show slave status\G" | runuser $MYSQLCLIENT | \
			awk '/Master_Host:/ {print $2}'`
        echo 'update global_configuration_local set value="passive" \
			where name="appserver.mode"' | runuser $MYSQLCLIENT
        echo 'update global_configuration_local set value="secondary" \
			where name="ha.controller.type"' | runuser $MYSQLCLIENT
		runuser ssh $secondary "$APPD_ROOT/HA/failover.sh" \
			-n primary_has_been_set_passive_and_stopped >/dev/null
	fi

	if [ -e "$APPD_ROOT/logs/server.log.lck" ] ; then
		runuser rm -f "$APPD_ROOT/logs/server.log.lck"
	fi
	rm -f $lockfile
;;

restart)  
	$0 stop  
	$0 start  
;;  
  
status)  
	retcode=0
	service appdcontroller-db status
	if watchdog_running ; then
		echo watchdog running
		if [ -f $WATCHDOG_STATUS ] ; then
			cat $WATCHDOG_STATUS
		fi
	else
		echo watchdog not running
	fi
	if assassin_running ; then
		echo assassin running
	else
		echo assassin not running
	fi
	controllerrunning
	case $? in
	0)
		echo "controller running"
		;;
	1)
		echo "controller started - not up"
		retcode=1
		;;
	*)
		echo "controller not running"
		retcode=1
		;;
	esac
	events_running
	case $? in
	0)
		echo "events service running"
		;;
	*)
		echo "events service not running"
		;;
	esac
	reporting_running
	case $? in
	0)
		echo "reporting service running"
		;;
	*)
		echo "reporting service not running"
		;;
	esac
	service appdynamics-machine-agent status
	exit $retcode
;;

*)  
        echo "Usage: $0 {start|stop|restart|status}"  
        exit 1  
esac
exit 0 
