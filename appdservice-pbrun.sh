#!/bin/bash
#
# $Id: appdservice-pbrun.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# shell wrapper around pbrun for appdynamics service changes
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
PBRUN=/usr/local/bin/pbrun

function usage {
	echo usage: "$0 [appdcontroller|appdcontroller-db|appdynamics-machine-agent start|stop|status]"
	exit 1
}

if [ ! -x $PBRUN ] ; then
	echo $0: pbrun not found at $PBRUN
	exit 2
fi

if [ $# -ne 2 ] ; then
	usage
fi

case $1 in
	appdcontroller|appdcontroller-db|appdynamics-machine-agent)
		service=$1
		;;
	*)
		usage
		;;
esac

case $2 in
	start|stop|status)
		action=$2
		;;
	*)
		usage
		;;
esac

$PBRUN -p -b /sbin/service $service $action
exit 0
