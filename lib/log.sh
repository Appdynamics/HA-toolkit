#!/bin/bash
#
# $Id: log.sh 3.3 2016-12-05 14:36:20 cmayer $
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
#

# this function should have no external dependencies and so should be callable
# from anywhere...returning 0 for success or non-zero for failure
# Call as:
#  APPD_ROOT=$(get_appd_root) || exit 1
function get_appd_root {
	local cwd=$(pwd -P || readlink -e .)
	if [[ "${cwd##*/}" != "HA" ]] ; then
		echo "ERROR: ${FUNCNAME[0]}: must be run within 'HA' sub-directory of controller install directory" >&2
		return 1
	fi
	echo $(readlink -e ..)
}

if [ -z "$APPD_ROOT" ] ; then
	# let's also check that whoever is calling us has cd'd to the HA directory
	APPD_ROOT=$(get_appd_root) || exit 1
fi

if [[ -z "$LOGNAME" ]] ; then
   echo "ERROR: ${FUNCNAME[0]}: LOGNAME variable is not set. This is a coding bug!" >&2
   exit 1
fi

#
# function to mask passwords
#
function pwmask {
	sed -u -e 's/--password=[^ ]*/--password=/'
}

# Init processes at startup should not log into $APPD_ROOT as generally that is
# reserved for $RUNUSER EUID processes. Instead will send output elsewhere by
# assigning full path instead of just filename to LOGNAME
if [[ "${LOGNAME:0:1}" != "/" ]] ; then
	LOGFILE=$APPD_ROOT/logs/$LOGNAME	# caller needs path adding
else
	LOGFILE=$LOGNAME			# assume caller wants specific path
fi

function log {
	local out
	if [[ -t 0 ]] ; then
		out=/dev/tty
	else
		out=/dev/null
	fi

	pwmask | tee -a $LOGFILE > $out
}

function logonly {
	pwmask >> $LOGFILE
}

# output to STDERR and to log file
function warn {
	echo "$@" >&2
	logmsg "$@"
}

# output to /dev/tty only - no log file entry
function gripe {
	local out=/dev/stderr	# otherwise why gripe?

	echo "$@" > $out
}

function logmsg {
	echo "  -- " "$@" >> $LOGFILE
}

function message {
	local out
	if [[ -t 0 ]] ; then
		out=/dev/tty
	else
		out=/dev/null
	fi

	echo "  -- " "$@" > $out
	logmsg "$@"
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

function debug
{
   while read -p '?dbg> ' L ; do
      eval "$L"
   done < /dev/tty
}
