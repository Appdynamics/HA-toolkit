#!/bin/bash
#
# print out the status of the appdynamics controller on this node
#
# $Id: appdstatus.sh 3.12 2017-03-07 17:04:25 cmayer $
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
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

LOGFNAME=status.log

. lib/log.sh
. lib/runuser.sh
. lib/password.sh
. lib/conf.sh
. lib/sql.sh
. lib/status.sh

if [ ! -f $APPD_ROOT/db/db.cnf ] ; then
	echo appd controller not installed in $APPD_ROOT
	exit 1
fi

if db_running ; then
	controllerversion=`sql localhost "select value from global_configuration_cluster where name='schema.version'" | get value`
	if [ ! -z "$controllerversion" ] ; then
		echo version: $controllerversion
	fi
	echo -n "db running as $RUNUSER - "
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

if [ $(dbcnf_get skip-slave-start) != unset ] ; then
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

if [ -f $APPD_ROOT/HA/numa.settings ] ; then
	numastat mysqld java
fi

exit 0 
