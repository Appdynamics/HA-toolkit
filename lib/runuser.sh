#!/bin/bash
#
# $Id: lib/runuser.sh 3.17 2017-04-18 14:48:02 cmayer $
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
# contains function stubs to make the runuser hook disappear
# this file is intended to be included by shell scripts running
# as the appdynamics user only.
#
# init scripts are intended to embed lib/init.sh instead
# 
# finally, if we are root, then this means that root had better
# be the user defined in db.cnf
#

function bg_runuser {
	echo "$*" | exec nohup bash >/dev/null 2>&1 &
}
function runuser {
	echo "$*" | bash
}
function run_mysql {
	$MYSQLCLIENT
}
export -f runuser bg_runuser
