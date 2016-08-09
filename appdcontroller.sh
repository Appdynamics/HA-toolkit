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
# $Id: appdcontroller.sh 3.0 2016-08-04 03:09:03 cmayer $
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
PATH=/bin:/usr/bin:/sbin:/usr/sbin

NAME=$(basename $(readlink -e $0))

APPD_ROOT=/opt/AppDynamics/Controller
RUNUSER=root

# source script config
[ -f /etc/sysconfig/appdcontroller ] && . /etc/sysconfig/appdcontroller
[ -f /etc/default/appdcontroller ] && . /etc/default/appdcontroller

OPEN_FD_LIMIT=65536

APPD_BIN="$APPD_ROOT/bin"
lockfile=/var/lock/subsys/$NAME
WATCHDOG=$APPD_ROOT/HA/appd_watchdog.pid
ASSASSIN=$APPD_ROOT/HA/appd_assassin.pid
WATCHDOG_ENABLE="$APPD_ROOT/HA/WATCHDOG_ENABLE"
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status
APPSERVER_DISABLE="$APPD_ROOT/HA/APPSERVER_DISABLE"

# For security reasons, locally embed/include function library at HA.shar build time
embed lib/password.sh
embed lib/init.sh
embed lib/conf.sh

check_sanity

DB_PID_FILE=`dbcnf_get pid-file`
DB_DATA_DIR=`dbcnf_get datadir`
DB_SKIP_SLAVE_START=`dbcnf_get skip-slave-start`

MYSQLCLIENT="$APPD_ROOT/HA/mysqlclient.sh"

if [ -f $APPD_ROOT/HA/LARGE_PAGES_ENABLE ] ; then
	ENABLE_HUGE_PAGES="true"
fi

function enable_pam_limits {
	if [ -f /etc/pam.d/common-session ] && ! grep  -Eq "^\s*session\s+required\s+pam_limits\.so" /etc/pam.d/common-session
		then
		echo "session required	pam_limits.so" >> /etc/pam.d/common-session
	elif [ -f /etc/pam.d/system-auth ] && ! grep  -Eq "^\s*session\s+required\s+pam_limits\.so" /etc/pam.d/system-auth
		then
		echo "session required	pam_limits.so" >> /etc/pam.d/system-auth
	fi
}

# always make sure this gets called before any other functions that modify
# /etc/security/limits.d/appdynamics.com, i.e. set_unlimited_memlock
function set_open_fd_limits {
	if [ "$RUNUSER" == "root" ] && [[ `ulimit -S -n` -lt $OPEN_FD_LIMIT ]]
		then
		ulimit -n $OPEN_FD_LIMIT
	elif [[ `su -s /bin/bash -c "ulimit -S -n" $RUNUSER` -lt "$OPEN_FD_LIMIT" ]]
		then
		echo "$RUNUSER  soft  nofile $OPEN_FD_LIMIT" > /etc/security/limits.d/appdynamics.conf
		echo "$RUNUSER  hard  nofile $OPEN_FD_LIMIT" >> /etc/security/limits.d/appdynamics.conf
		enable_pam_limits
	fi
}

function set_unlimited_memlock {
	if [ "$ENABLE_HUGE_PAGES" == "true" ] ; then
		if [[ $RUNUSER == "root" ]]
			then
			ulimit -l unlimited
		else
			if [[ $(su -s /bin/bash -c "ulimit -l" $RUNUSER) != "unlimited" ]]
				then
				echo "$RUNUSER  soft  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
				echo "$RUNUSER  hard  memlock  unlimited" >> /etc/security/limits.d/appdynamics.conf
				enable_pam_limits
			fi
		fi
	fi
}

function watchdog_running {
	if runuser [ -f "$WATCHDOG" ] ; then
		WATCHPID=`runuser cat $WATCHDOG`
		if [ ! -z "$WATCHPID" ] ; then
			if [ -d /proc/$WATCHPID ] ; then
				return 0
			fi
		fi
	fi
	return 1
}

function assassin_running {
	if runuser [ -f "$ASSASSIN" ] ; then
		ASSASSINPID=`runuser cat $ASSASSIN`
		if [ ! -z "$ASSASSINPID" ] ; then
			if [ -d /proc/$ASSASSINPID ] ; then
				return 0
			fi
		fi
	fi
	return 1
}

function db_running {
	local DB_PID=

	if [ -z "$DB_PID_FILE" ] ; then
		DB_PID_FILE="$DB_DATA_DIR/$(hostname).pid"
	fi
	if [ -z "$DB_PID_FILE" ] ; then
		return 1
	fi
	if runuser [ -f $DB_PID_FILE ] ; then
		DB_PID=`runuser cat $DB_PID_FILE`
	fi
	if [ -z "$DB_PID" ] ; then
		return 1
	fi
	if [ -d /proc/$DB_PID ] ; then
		return 0;
	fi
	return 1	
}

function replication_disabled {

	if [ -n "$DB_SKIP_SLAVE_START" ] ; then
		return 0
	else
		return 1
	fi
}

function get {
	local key
	awk "/$key:/ {print \$2}"
}

function controller_mode {
	echo "select value from global_configuration_local \
		where name='appserver.mode'" | runuser $MYSQLCLIENT | get value
}

#
# this is a check for the controller running
# 0: controller running
# 1: controller started
# 2: controller process around, but domain doesn't report up
# 3: nothing visible
# 
function controllerrunning {
	if pgrep -f -u $RUNUSER "$APPD_ROOT/jre/bin/java -jar ./../modules/admin-cli.jar" >/dev/null ; then
		return 1
	fi
	if runuser $APPD_ROOT/appserver/glassfish/bin/asadmin list-domains | \
		grep -q "domain1 running" ; then
		return 0
	fi
	if pgrep -f -u $RUNUSER "$APPD_ROOT/appserver/glassfish/domains/domain1" >/dev/null ; then
		return 2
	fi
	return 3
}

function events_running {
	if ps -f -u $RUNUSER | grep "$APPD_ROOT/jre/bin/java" | grep "$APPD_ROOT/events_service" >/dev/null ; then
		return 0
	fi
	return 1
}

function reporting_running {
	if pgrep -f -u $RUNUSER "$APPD_ROOT/reporting_service/nodejs/bin/node" >/dev/null ; then
		return 0
	fi
	return 1
}

function machine_agent_running {
	if service appdynamics-machine-agent status &> /dev/null; then
		return 0
	else
		return 1
	fi
}

case "$1" in
start)  
	require_root
	if runuser [ -f $APPSERVER_DISABLE ] ; then
		echo appdcontroller disabled - incomplete replica:w
		exit 1
	fi
	service appdcontroller-db start
	set_open_fd_limits
	set_unlimited_memlock
	if [[ `id -u $RUNUSER` != "0" ]] && use_privileged_ports ; then
		#trying to bind java to a privilged port as an unpriviliged user
		setcap cap_net_bind_service=+ep $APPD_ROOT/jre/bin/java
		echo "$APPD_ROOT/jre/lib/$(uname -m | sed -e 's/x86_64/amd64/')/jli" > \
			/etc/ld.so.conf.d/appdynamics.conf
		ldconfig            
	fi
	if [ "`controller_mode`" == "active" ] ; then
		bg_runuser $APPD_BIN/controller.sh start-appserver >/dev/null
		if replication_disabled ; then
			if assassin_running ; then
				echo assassin already running
			else
				echo starting assassin 
				bg_runuser $APPD_ROOT/HA/assassin.sh
			fi
		fi
		if runuser [ -d $APPD_ROOT/events_service ] ; then
			bg_runuser $APPD_BIN/controller.sh start-events-service >/dev/null
		fi
		if runuser [ -d $APPD_ROOT/reporting_service ] ; then
			bg_runuser $APPD_BIN/controller.sh start-reporting-service >/dev/null
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
				bg_runuser $APPD_ROOT/HA/watchdog.sh >/dev/null
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
		kill -9 $WATCHPID && ( echo appd watchdog killed; \
		runuser "echo `date` appd watchdog killed >> $APPD_ROOT/logs/watchdog.log" )
	fi
	runuser rm -f $WATCHDOG
	if assassin_running ; then
		kill -9 $ASSASSINPID && ( echo appd assassin killed; \
		runuser "echo `date` appd assassin killed >> $APPD_ROOT/logs/assassin.log" )		
	fi
	runuser rm -f $ASSASSIN
	# TODO: stop automatically starting and stopping the local events service since
	#   an HA controller pair should be talking to a separate events service cluster.
	if runuser [ -d $APPD_ROOT/events_service ] ; then
		runuser $APPD_BIN/controller.sh stop-events-service
	fi
	if runuser [ -d $APPD_ROOT/reporting_service ] ; then
		runuser $APPD_BIN/controller.sh stop-reporting-service
	fi
	# The default controller shutdown timeout is 45 minutes 
	# That is a long time to be stuck with a hung appserver on the way down.
	# Thankfully, we can set an environment variable to override that:
	export AD_SHUTDOWN_TIMEOUT_IN_MIN=10
    runuser $APPD_BIN/controller.sh stop-appserver
	controllerrunning
	if [ $? -lt 3 ] ; then
		echo "forcibly killing appserver"
		pkill -9 -f "$APPD_ROOT/appserver/glassfish/domains/domain1"
		echo "truncate ejb__timer__tbl;" | runuser $MYSQLCLIENT 
	fi

	if [ -e $APPD_ROOT/logs/server.log.lck ] ; then
		runuser rm -f $APPD_ROOT/logs/server.log.lck
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
	machine_agent_running
	case $? in
	0)
		echo "machine-agent service running"
		;;
	*)
		echo "machine-agent service not running"
		;;
	esac
	exit $retcode
;;

*)  
        echo "Usage: $0 {start|stop|restart|status}"  
        exit 1  
esac
exit 0 
