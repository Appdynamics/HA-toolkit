#!/bin/bash
#
# $Id: uninstall-init.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# uninstall init script
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
export PATH=/sbin:/usr/sbin:$PATH

function remove {
	if rpm -qi --quiet $1 2>/dev/null; then return; fi	# skip if rpm package installed

	if [ ! -f /etc/init.d/$1 ] ; then
		return
	fi
	if [[ -x `which chkconfig 2>/dev/null` ]] ; then
		chkconfig --del $1
		rm -f /etc/sysconfig/$1
	elif [[ -x `which update-rc.d 2>/dev/null` ]] ; then
		update-rc.d -f $1 remove
		rm -f /etc/default/$1
	else
		echo "Failed to remove $1: chkconfig or update-rc.d required"
		exit 1
	fi

	echo removing $1 service
	rm -f /etc/init.d/$1
}

remove appdcontroller
remove appdcontroller-db
remove appdynamics-machine-agent

if [ -f /sbin/appdservice ] ; then
	echo removing appdservice wrapper
	rm -f /sbin/appdservice
fi

if [ -f /etc/sudoers.d/appdynamics ] ; then
	echo removing appdynamics specific sudoers file
	rm -f /etc/sudoers.d/appdynamics

	if grep -Eq "^#include[\t ]+/etc/sudoers.d/appdynamics[\t ]*$" /etc/sudoers ; then
		echo removing sudoers additions
		ex -s /etc/sudoers <<- RMAPPD
			g/^#include[\t ][\t ]*\/etc\/sudoers.d\/appdynamics/d
			wq
		RMAPPD
	fi
fi
