#!/bin/bash
#
# $Id: lib/runuser.sh 3.20 2018-01-21 22:10:49 rob.navarro $
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

####
# Contains definition of RUNUSER (effective user) as well as the
# family of utility functions to wrap commands that sometimes need 
# to be run as the current user and sometime as the effective user of
# AppD.
#
# Generally the rule is if current effective UID != to the MySQL user
# then cause all filesystem accesses to run with the effective UID
# of the MySQL user.
#
# These wrapper functions are needed to:
# 1.  prevent processes started as root from making files that 
#     non-root users can then later not read.
# 2.  enable root started processes from accessing NFS mounted filestore
#
# This file needs to be included or embedded prior to any use of the
# the runuser, bg_runuser wrapper functions
####

#
# This function has only 2 external dependencies:
# 1. APPD_ROOT is set
# 2. $APPD_ROOT/db/db.cnf is readable by current user
#
# Returns the username referenced by MySQL's db/db.cnf as the single
# most reliable record of which effective user AppD should run as.
#
# Avoids unpleasant cyclic dependency by just ASSUMING $APPD_ROOT/db/db.cnf
# is readable. Otherwise using runuser() functions assume the existence of
# $RUNUSER... which has not yet been determined.
#
# Remember that when called by Init script RUNUSER will already have
# been set.
# Call as:
#  RUNUSER=$(get_runuser) || exit 1
function get_runuser {
	if [[ -z "$APPD_ROOT" ]] ; then
		echo "ERROR: ${FUNCNAME[0]}: APPD_ROOT is not set. This is a coding bug! " >&2
		exit 1
	fi
	local euser RETC
	euser=$(awk -F= '$1 ~ /^[[:space:]]*user$/ {print $2}' $APPD_ROOT/db/db.cnf)
	RETC=$?

	if (( $RETC != 0 )) ; then
		echo "ERROR: ${FUNCNAME[0]}: APPD_ROOT is not set correctly." >&2
		exit 1
	fi
	if [[ -z "$euser" ]] ; then
		if grep -q user=  $APPD_ROOT/db/db.cnf &>/dev/null; then
			echo "ERROR: ${FUNCNAME[0]}: your awk version needs upgrading. Please install gawk." >&2
		else
			echo "ERROR: ${FUNCNAME[0]}: $APPD_ROOT/db/db.cnf is not valid MySQL config - missing user=... option." >&2
		fi
		exit 1
	fi
	echo $euser
}

if [[ -z "$RUNUSER" ]] ; then
	RUNUSER=$(get_runuser) || exit 1
fi

#
# runuser quoting is a definite PITA.  the way to stay sane is to note
# exactly when you want $ to be expanded and make that explicit, passing
# escaped $ signs when you want the expansion deferred
#
# finally, the bg_runuser function should return the pid
#
if [[ `id -un` == "$RUNUSER" ]] ; then
        function bg_runuser {
#               echo "$* >/dev/null 2>&1 & echo \$! ; disown" | bash &
		bash -c "$* &>> ${logfile:-/dev/null} </dev/null & echo \$! ; disown"
        }
        function run_mysql {
                $MYSQLCLIENT
        }
        function runuser {
#               echo "$*" | bash
                bash -c "$*"
        }
else
        function bg_runuser {
#               echo "$* >/dev/null & echo \$! ; disown" | su -s /bin/bash $RUNUSER
		su -s /bin/bash ${RUNUSER:-unset_runuser} -c "$* &>> ${logfile:-/dev/null} </dev/null & echo \$! ; disown"
        }
        function run_mysql {
#               su -s $MYSQLCLIENT $RUNUSER
                su -s /bin/bash ${RUNUSER:-unset_runuser} -c $MYSQLCLIENT
        }
        function runuser {
#               echo "$*" | su -s /bin/bash $RUNUSER
                su -s /bin/bash ${RUNUSER:-unset_runuser} -c "$*"
        }
fi
export -f runuser bg_runuser run_mysql
