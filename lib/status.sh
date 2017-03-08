#!/bin/bash
#
# $Id: lib/status.sh 3.11 2017-03-03 00:28:47 cmayer $
#
# common code to interrogate the status of various functions
#
# can be included by init or other scripts
# Copyright 2016 AppDynamics, Inc
#
#	Licensed under the Apache License, Version 2.0 (the "License");
#	you may not use this file except in compliance with the License.
#	You may obtain a copy of the License at
#
#		http://www.apache.org/licenses/LICENSE-2.0
#
#	Unless required by applicable law or agreed to in writing, software
#	distributed under the License is distributed on an "AS IS" BASIS,
#	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#	See the License for the specific language governing permissions and
#	limitations under the License.
#

function watchdog_running {
	if runuser [ -f "$WATCHDOG_PIDFILE" ] ; then
		watchdog_pid=`runuser cat $WATCHDOG_PIDFILE`
		if [ ! -z "$watchdog_pid" ] ; then
			if [ -d /proc/$watchdog_pid ] ; then
				return 0
			fi
		fi
	fi
	rm -f $WATCHDOG_PIDFILE
	return 1
}

function assassin_running {
	if runuser [ -f "$ASSASSIN_PIDFILE" ] ; then
		assassin_pid=`runuser cat $ASSASSIN_PIDFILE`
		if [ ! -z "$assassin_pid" ] ; then
			if [ -d /proc/$assassin_pid ] ; then
				return 0
			fi
		fi
	fi
	rm -f $ASSASSIN_PIDFILE
	return 1
}

function replication_disabled {
	if [ $(dbcnf_get skip-slave-start) = true ] ; then
		return 0
	else
		return 1
	fi
}

function db_running {
    if [ "$DB_PID_FILE" = "unset" ] ; then
        DB_PID_FILE="$DB_DATA_DIR/$(hostname).pid"
    fi
    if runuser [ -f $DB_PID_FILE ] ; then
        DB_PID=`runuser cat $DB_PID_FILE 2>/dev/null`
    fi
    if [ -z "$DB_PID" ] ; then
        return 1
    fi   
    if [ -d /proc/$DB_PID ] ; then
        return 0;
    fi 
    return 1
}

function get {
	local key
	awk "/$key:/ {print \$2}"
}

function controller_mode {
	echo "select value from global_configuration_local \
		where name='appserver.mode'" | runuser $MYSQLCLIENT | get value
}

function controllerrunning {
	if pgrep -f -u $RUNUSER "$APPD_ROOT/jre/bin/java -jar ./../modules/admin-cli.jar" >/dev/null ; then
		return 1
	fi
	if runuser "$APPD_ROOT/appserver/glassfish/bin/asadmin" list-domains | \
		grep -q "domain1 running" ; then
		return 0
	fi
	if pgrep -f -u $RUNUSER "$APPD_ROOT/appserver/glassfish/domains/domain1" >/dev/null ; then
		return 2
	fi
	return 3
}

function events_running {
	if ps -f -u $RUNUSER | grep "java" | grep "$APPD_ROOT/events_service" >/dev/null ; then
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
	if pgrep -f -u $RUNUSER machineagent.jar > /dev/null; then
		return 0
	else
		return 1
	fi
}

