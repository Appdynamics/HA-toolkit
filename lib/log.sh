#!/bin/bash
#
# $Id: lib/log.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# logging code for the HA toolkit - include this first
#
# all use the global LOGNAME
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
if [ -z "$APPD_ROOT" ] ; then
	APPD_ROOT=$( cd $(dirname "$0"); cd .. ; pwd -P)
fi

#
# function to mask passwords
#
function pwmask {
	sed -e 's/--password=[^ ]*/--password=/'
}

LOGFILE=$APPD_ROOT/logs/$LOGNAME

function log {
	local out=/dev/tty
	if ! [ -c $out ] ; then
		out=/dev/null
	fi

	pwmask | tee -a $LOGFILE > $out
}

function logonly {
	pwmask >> $LOGFILE
}

function gripe {
	local out=/dev/tty
	if ! [ -c $out ] ; then
		out=/dev/null
	fi

	echo "$@" > $out
}

function logmsg {
	echo "  -- " "$@" >> $LOGFILE
}

function message {
	local out=/dev/tty
	if ! [ -c $out ] ; then
		out=/dev/null
	fi

	echo "  -- " "$@" > $out
	logmsg "$@"
}

function sqlerr {
    if [ -z "$SQL_ERROR" ] ; then
        pwmask >> $LOGFILE
    else
        pwmask >> $SQL_ERROR
    fi
}

#
# this indicates a coding error, so let's print a useful backtrace
# as in guten abend
#
function abend {
	local lines=($((LINENO-1)) ${BASH_LINENO[*]})
	local level=0

	gripe "$@"
	echo "exit code $exitcode" | log
	echo "backtrace: " | log
	for func in ${FUNCNAME[*]} ; do
		echo "${FUNCNAME[$level]}() ${BASH_SOURCE[$level]}:${lines[$level]}" | log
		level=$((level+1))
	done
	kill -INT $$
}

#
# this is a runtime failure
#
function fatal {
	local exitcode=$1
	shift
	gripe "$@"
	gripe "exit code $exitcode"
	kill -INT $$
	exit $exitcode
}

#
# rename the log
#
function log_rename {
	if [ -e $LOGFILE ] ; then
		message "log renamed" `date`
		mv $LOGFILE $LOGFILE.`date +%F.%T`
	fi
}

