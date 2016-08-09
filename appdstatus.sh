#!/bin/bash
#
# print out the status of the appdynamics controller on this node
#
# $Id: appdstatus.sh 3.0 2016-06-29 12:58:56 cmayer $
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

cd $(dirname $0)

LOGNAME=status.log

. lib/log.sh
. lib/runuser.sh
. lib/password.sh
. lib/conf.sh
. lib/sql.sh

ASSASSIN=$APPD_ROOT/HA/appd_assassin.pid

WATCHDOG_ENABLE="$APPD_ROOT/HA/WATCHDOG_ENABLE"
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status
WATCHDOG=$APPD_ROOT/HA/appd_watchdog.pid
APPSERVER_DISABLE="$APPD_ROOT/HA/APPSERVER_DISABLE"

DB_PID_FILE=`dbcnf_get pid-file`
DB_DATA_DIR=`dbcnf_get datadir`
DB_SKIP_SLAVE_START=`dbcnf_get skip-slave-start`

function watchdog_running {
	if [ -f "$WATCHDOG" ] ; then
		WATCHPID=`cat $WATCHDOG`
		if [ ! -z "$WATCHPID" ] ; then
			if [ -d /proc/$WATCHPID ] ; then
				return 0
			fi
		fi
	fi
	return 1
}

function assassin_running {
	if [ -f "$ASSASSIN" ] ; then
		ASSASSINPID=`cat $ASSASSIN`
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
	if [ -f $DB_PID_FILE ] ; then
		DB_PID=`cat $DB_PID_FILE`
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

#
# this is a check for the controller running
# 0: controller running
# 1: controller started
# 2: controller process around, but domain doesn't report up
# 3: nothing visible
# 
function controllerrunning {
        if pgrep -f -u $dbuser "$APPD_ROOT/jre/bin/java -jar ./../modules/admin-cli.jar" >/dev/null ; then
                return 1
        fi
        if $APPD_ROOT/appserver/glassfish/bin/asadmin list-domains | \
                grep -q "domain1 running" ; then
                return 0
        fi
        if pgrep -f -u $dbuser "$APPD_ROOT/appserver/glassfish/domains/domain1" >/dev/null ; then
                return 2
        fi
        return 3
}

function events_running {
	if ps -f -u $dbuser | grep "$APPD_ROOT/jre/bin/java" | grep "$APPD_ROOT/events_service" >/dev/null ; then
		return 0
	fi
	return 1
}

function reporting_running {
	if pgrep -f -u $dbuser "$APPD_ROOT/reporting_service/nodejs/bin/node" >/dev/null ; then
		return 0
	fi
	return 1
}

function machine_agent_running {
	if pgrep -f -u $dbuser machineagent.jar > /dev/null; then
		return 0
	else
		return 1
	fi
}

if [ ! -f $APPD_ROOT/db/db.cnf ] ; then
	echo appd controller not installed in $APPD_ROOT
	exit 1
fi

if db_running ; then
	controllerversion=`sql localhost "select value from global_configuration_cluster where name='schema.version'" | get value`
	if [ ! -z "$controllerversion" ] ; then
		echo version: $controllerversion
	fi
	echo -n "db running as $dbuser - "
	if [ "`get_replication_mode localhost`" == "active" ] ; then
		echo "active"
	else
		echo "passive"
	fi

	case `sql localhost "select value from global_configuration_local where name='ha.controller.type'" | get value` in
	primary) 
		echo primary
		;;
	secondary)
		echo secondary
		;;
	notapplicable)
		echo HA not installed
		;;
	*)
		echo unknown HA type
		;;
	esac
		
	sql localhost "SHOW SLAVE STATUS" | awk \
			'/Slave_IO_State/ {print}
			/Seconds_Behind_Master/ {print} 
			/Master_Server_Id/ {print}
			/Master_Host/ {print}'
	sql localhost "SHOW SLAVE STATUS" | awk '
			/Master_SSL_Allowed/ { if ($2 == "Yes") {print "Using SSL Replication" }}'
else
	echo "db not running"
fi

if [ -n "`dbcnf_get skip-slave-start`" ] ; then
	echo "replication persistently broken"
fi

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
	;;
2)
	echo "controller zombie"
	;;
*)
	echo "controller not running"
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

exit 0 
