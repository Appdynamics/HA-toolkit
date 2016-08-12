#!/bin/bash
#
# $Id: appdynamics-machine-agent.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# /etc/init.d/appdynamics-machine-agent
#
# This file describes the machine agent service. Copy it or place it in 
# /etc/init.d to ensure the machine agent is started as a service. 
# If you installed the machine agent via an RPM or DEB package, it should
# already be placed there.
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
### BEGIN INIT INFO
# Provides:          appdynamics-machine-agent
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Required-Start:
# Required-Stop:
# Short-Description: AppDynamics Machine Agent
# Description:       Enable AppDynamics Machine Agent service provided by daemon.
### END INIT INFO

# Setting PATH to just a few trusted directories is an **important security** requirement
PATH=/bin:/usr/bin:/sbin:/usr/sbin

prog="appdynamics-machine-agent"
pidfile="/var/run/appdynamics/$prog"
lockfile="/var/lock/subsys/$prog"

# Defaults. Do not edit these. They will be overwritten in updates.
# Override in /etc/sysconfig/appdynamics-machine-agent
APPD_ROOT=/opt/AppDybnamics/Controller
MACHINE_AGENT_HOME=/opt/appdynamics/machine-agent
RUNUSER=root
JAVA_OPTS=""

# source script config
[ -f /etc/sysconfig/appdynamics-machine-agent ] && . /etc/sysconfig/appdynamics-machine-agent
[ -f /etc/default/appdynamics-machine-agent ] && . /etc/default/appdynamics-machine-agent

JAVA=$APPD_ROOT/jre/bin/java

# For security reasons, locally embed/include function library at HA.shar build time
embed lib/init.sh

function start() {
    require_root

    mkdir -p /var/run/appdynamics
    chown $RUNUSER /var/run/appdynamics
    mkdir -p /var/lock/subsys
	rm -f $pidfile

	pid=`bg_runuser $JAVA $JAVA_OPTS -jar $MACHINE_AGENT_HOME/machineagent.jar`
	echo $pid > $pidfile
    touch $lockfile
}

function stop() {
    require_root

	if [ -f $pidfile ] ; then
		pid=`cat $pidfile`
		if [ -d /proc/$pid ] ; then
			kill -9 $pid
		fi
		rm -f $pidfile
	fi
    rm -f $lockfile
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        if [ -f /var/lock/subsys/$prog ] ; then
            stop
            # avoid race
            sleep 3
            start
        fi
        ;;
    status)
		if [ -f $pidfile ] ; then
			pid=`cat $pidfile`
			if [ -d /proc/$pid ] ; then
				exit 0
			fi
			rm -f $pidfile
		fi
		exit 1
        ;;
    *)  
        echo $"Usage: $0 {start|stop|restart|status}"
        exit 1
esac
exit 0
