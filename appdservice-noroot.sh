#!/bin/bash
#
# $Id: appdservice-noroot.sh 3.10 2017-02-15 18:00:41 cmayer $
#
# no root shell wrapper for appdynamics service changes
#
# this file is intended to be a limited replacement of the service
# escalation function, and as such needs to implement an adequate subset
# of the machinery in the init scripts
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
APPD_ROOT=`readlink -e ..`
NAME=$(basename $(readlink -e $0))

#
# turn on debugging if indicated
#
if [ -f $APPD_ROOT/HA/INITDEBUG ] ; then
        rm -f /tmp/$NAME.out
    exec 2> /tmp/$NAME.out
    set -x
fi

. lib/ha.sh

#
# load in customized sysconfig files if present
#
if [ -f appdynamics-machine-agent.sysconfig ] ; then
	. appdynamics-machine-agent.sysconfig
fi
if [ -f appdcontroller.sysconfig ] ; then
	. appdcontroller.sysconfig
fi

function usage {
	echo usage: "$0 [appdcontroller appdcontroller-db appdynamics-machine-agent] [start stop status]"
	exit 1
}

if [ $# -ne 2 ] ; then
	usage
fi

service=$1
verb=$2

case "$service:$verb" in

appdcontroller:status|appdcontroller-db:status|appdynamics-machine-agent:status)
	./appdstatus.sh
	;;
	
appdcontroller:start)
	./appdservice-noroot.sh appdcontroller-db start
	if echo 'select value from global_configuration_local where name = "appserver.mode"' | ./mysqlclient.sh | grep -q active ; then
		nohup $APPD_ROOT/bin/controller.sh start-appserver &
		if [ -d "$APPD_ROOT/events_service" ] ; then
			nohup $APPD_ROOT/bin/controller.sh start-events-service &
		fi
		if [ -d "$APPD_ROOT/reporting_service" ] ; then
			nohup $APPD_ROOT/bin/controller.sh start-reporting-service &
		fi
	fi
	;;

appdcontroller:stop)
	$APPD_ROOT/bin/controller.sh stop-appserver
	if [ -d "$APPD_ROOT/events_service" ] ; then
		$APPD_ROOT/bin/controller.sh stop-events-service
	fi
	if [ -d "$APPD_ROOT/reporting_service" ] ; then
		$APPD_ROOT/bin/controller.sh stop-reporting-service
	fi
	;;

appdcontroller-db:start)
	$APPD_ROOT/bin/controller.sh start-db
	false
	;;

appdcontroller-db:stop)
	./appdservice-noroot.sh appdcontroller stop
	$APPD_ROOT/bin/controller.sh stop-db
	;;

appdynamics-machine-agent:start)
	ma_dir=`find_machine_agent`
	if [ ! -d "$ma_dir" ] ; then
		exit 0
	fi
	nohup $APPD_ROOT/jre/bin/java $JAVA_OPTS -jar $ma_dir/machineagent.jar &
	;;

appdynamics-machine-agent:stop)
	for pid in `pgrep -f machineagent.jar` ; do
		for sub in `pgrep -P $pid` ; do
			kill -9 $sub
		done
		kill -9 $pid
	done
	;;

*)
	usage
	;;
esac

exit 0
