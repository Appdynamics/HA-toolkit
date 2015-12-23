#!/bin/bash
#
# $Id: appdservice-pbrun.sh 1.1 2015-12-23 00:36:28 cmayer $
#
# shell wrapper around pbrun for appdynamics service changes
#
PBRUN=/usr/local/bin/pbrun

function usage {
	echo usage: "$0 [appdcontroller appdcontroller-db] [start stop status]"
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
	appdcontroller|appdcontroller-db)
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

$PBRUN -b /sbin/service $service $action
exit 0
