#!/bin/bash
#
# $Id: uninstall-init.sh 1.5 2015-08-24 14:37:53 cmayer $
#
# uninstall init script
#
export PATH=/sbin:/usr/sbin:$PATH

function remove() {
	if [ ! -f /etc/init.d/$1 ] ; then
		return
	fi
	if [[ -x `which chkconfig 2>/dev/null` ]] ; then
		chkconfig --del $1
	elif [[ -x `which update-rc.d 2>/dev/null` ]] ; then
		update-rc.d -f $1 remove
	else
		echo "Failed to remove $1: chkconfig or update-rc.d required"
		exit 1
	fi
	echo removing $1 service
	rm -f /etc/init.d/$1
}

remove appdcontroller
remove appdcontroller-db

if [ -f /sbin/appdservice ] ; then
	echo removing appdservice wrapper
	rm -f /sbin/appdservice
fi

if [ -f /etc/sudoers.d/appdynamics ] ; then
	echo removing appdynamics specific sudoers file
	rm -f /etc/sudoers.d/appdynamics

	if grep -Eq "^#include[\t ]+/etc/sudoers.d/appdynamics[\t ]*$" /etc/sudoers ; then
		echo removing sudoers additions
		ed -s /etc/sudoers <<- RMAPPD
			g/^#include[\t ][\t ]*\/etc\/sudoers.d\/appdynamics/d
			wq
		RMAPPD
	fi
fi
