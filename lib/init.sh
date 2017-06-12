#!/bin/bash
#
# $Id: lib/init.sh 3.17 2017-04-18 14:48:02 cmayer $
#
# init.sh
# contains functions to change user and run processes
# 
# also, common code for the init scripts.
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
# runuser quoting is a definite PITA.  the way to stay sane is to note
# exactly when you want $ to be expanded and make that explicit, passing
# escaped $ signs when you want the expansion deferred
#
# finally, the bg_runuser function should return the pid
#
if [ `id -un` == "$RUNUSER" ] ; then
	function bg_runuser {
#		echo "$* >/dev/null 2>&1 & echo \$! ; disown" | bash &
		nohup bash -c "$* &>/dev/null <&- & echo \$! ; disown" &
	}
	function run_mysql {
		$MYSQLCLIENT
	}
	function runuser {
		echo "$*" | bash
	}
else
	function bg_runuser {
#		echo "$* >/dev/null & echo \$! ; disown" | su -s /bin/bash $RUNUSER
		nohup bash -c "su -s /bin/bash $RUNUSER $* &>/dev/null <&- & echo \$! ; disown" &
	}
	function run_mysql {
		su -s $MYSQLCLIENT $RUNUSER
	}
	function runuser {
		echo "$*" | su -s /bin/bash $RUNUSER
	}
fi
export -f runuser bg_runuser

# enable Debian systems to work also
function service {
    if [[ -z "$service_bin" ]] ; then
        if [[ -f /sbin/service ]] ; then
                service_bin=/sbin/service
        elif [[ -f /usr/sbin/service ]] ; then
                service_bin=/usr/sbin/service
        else
            echo service not found in /sbin or /usr/sbin - exiting
            exit 13
        fi
        $service_bin "$@"
    else
        $service_bin "$@"
    fi
}

function require_root {
    if [ `id -un` != "root" ] ; then
        echo "service changes must be run as root"
        exit 1
    fi
}

#
# trivial sanity check
#
function check_sanity {
	if runuser [ ! -f $APPD_ROOT/db/db.cnf ] ; then
		echo appd controller not installed in $APPD_ROOT
		exit 1
	fi
	if runuser [ ! -x $APPD_ROOT/bin/controller.sh ] ; then
		echo controller disabled on this host
		exit 1
	fi
}

