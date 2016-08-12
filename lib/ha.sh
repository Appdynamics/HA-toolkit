#!/bin/bash
#
# $Id: lib/ha.sh 3.0.1 2016-08-08 13:40:17 cmayer $
#
# ha.sh
# contains common code used by the HA toolkit
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
# filenames
#
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml
WATCHDOG_ENABLE=$APPD_ROOT/HA/WATCHDOG_ENABLE
WATCHDOG_SETTINGS=$APPD_ROOT/HA/watchdog.settings
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status
WATCHDOG_ERROR=$APPD_ROOT/logs/watchdog.error

#
# pidfiles
#
ASSASSIN_PID=$APPD_ROOT/HA/appd_assassin.pid
WATCHDOG_PID=$APPD_ROOT/HA/appd_watchdog.pid

# with help from:
# http://stackoverflow.com/questions/1923435/how-do-i-echo-stars-when-reading-password-with-read
function getpw { 
        (( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <variable name>"
        local pwch inpw1 inpw2=' ' prompt; 
        
        ref=$1 
	while [[ "$inpw1" != "$inpw2" ]] ; do
		prompt="Enter MySQL root password: "
		inpw1=''
		while read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				echo > /dev/tty
				break 
			else 
				prompt='*'
				inpw1+=$pwch 
			fi 
		done 

		prompt="re-enter same password: "
		inpw2=''
		while read -p "$prompt" -r -s -n1 pwch ; do 
			if [[ -z "$pwch" ]]; then 
				echo > /dev/tty
				break 
			else 
				prompt='*'
				inpw2+=$pwch 
			fi 
		done 
	
		[[ "$inpw1" == "$inpw2" ]] || echo "passwords unequal. Retry..." 1>&2
	done

	# indirect assignment (without local -n) needs eval. 
	# This only works with global variables :-( Please use weird variable names to
	# avoid namespace conflicts...
        eval "${ref}=\$inpw1"            # assign passwd to parameter variable
}

# helper function to allow separate setting of passwd from command line.
# Use this to persist an obfuscated version of the MySQL passwd to disk.
# Call as:
#  . hafunctions.sh
#  save_mysql_passwd $APPD_ROOT
function save_mysql_passwd {
	(( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <APPD_ROOT>"

	local thisfn=${FUNCNAME[0]} APPD_ROOT=$1 
	[[ -d $1 ]] || err "$thisfn: \"$1\" is not APPD_ROOT"
	local rootpw_obf="$APPD_ROOT/db/.rootpw.obf"

	getpw __inpw1 || exit 1		# updates __inpw1 *ONLY* if global variable
	obf=$(obfuscate $__inpw1) || exit 1
	echo $obf > $rootpw_obf || err "$thisfn: failed to save obfuscated passwd to $rootpw_obf"
	chmod 600 $rootpw_obf || warn "$thisfn: failed to make $rootpw_obf readonly"
}

#
# find out which escalation method we are using
#
if [ -f /sbin/service ] ; then
    service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
    service_bin=/usr/sbin/service
else
    fatal 1 "service not found in /sbin or /usr/sbin"
fi

#
# abstract out the privilege escalation at run time
#
# remservice <flags> <machine> <service> <verb>
# service <service> <verb>
#
if [[ `id -u` == 0 ]] ; then
	function service {
		$service_bin $1 $2
	}   
        
	function remservice {
		ssh $1 $2 $service_bin $3 $4
	}
else
	if [ -x /sbin/appdservice ] ; then
		function service {
			/sbin/appdservice $1 $2
		}
		function remservice {
			ssh $1 $2 /sbin/appdservice $3 $4
		}
	else
		function service {
			sudo $service_bin $1 $2
		}
		function remservice {
			ssh $1 $2 sudo -n $service_bin $3 $4
		}
    fi
fi

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
function check_sanity {
	if [ ! -d "$APPD_ROOT" ] ; then
		fatal 1 "controller root $APPD_ROOT is not a directory"
	fi
	if [ ! -w "$DB_CONF" ] ; then
		fatal 2 "db configuration $DB_CONF is not writable"
	fi
	if [ ! -x "$MYSQL" ] ; then
		fatal 3 "controller root $MYSQL is not executable"
	fi
	if [ `id -un` != $dbuser ] ; then
		fatal 4 "$0 must run as $dbuser"
	fi
}


