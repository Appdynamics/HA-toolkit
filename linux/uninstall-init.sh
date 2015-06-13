#!/bin/bash
#
# $Id: uninstall-init.sh 1.4 2015-06-12 12:22:17 cmayer $
#
# uninstall init script
#
export PATH=/sbin:/usr/sbin:$PATH

function remove() {
	if [[ -x `which chkconfig 2>/dev/null` ]] ; then
		chkconfig --del $1
	elif [[ -x `which update-rc.d 2>/dev/null` ]] ; then
		update-rc.d -f $1 remove
	else
		echo "Failed to remove $1: chkconfig or update-rc.d required"
		exit 1
	fi
	rm -f /etc/init.d/$1
}

remove appdcontroller
remove appdcontroller-db
