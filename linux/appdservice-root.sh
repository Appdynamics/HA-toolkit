#!/bin/bash
#
# $Id: appdservice-root.sh 1.1 2015-12-23 00:36:28 cmayer $
#
# shell wrapper around service for service changes - designed to run as root
#
function usage {
	echo usage: "$0 [appdcontroller appdcontroller-db] [start stop status]"
	exit 1
}

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

/sbin/service $service $action
exit 0
