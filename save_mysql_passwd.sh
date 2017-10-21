#!/bin/bash
#
# $Id: save_mysql_passwd.sh 3.13 2017-10-21 00:47:23 rob.navarro $
#
# a simple wrapper around the obfuscated password saver function
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
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

LOGNAME=save_mysql_passwd.log

. lib/log.sh
. lib/ha.sh
. lib/password.sh

if [ -x $APPD_ROOT/db/bin/mysql_config_editor ] ; then
	$APPD_ROOT/db/bin/mysql_config_editor reset
	$APPD_ROOT/db/bin/mysql_config_editor set --user=root -p
else
	save_mysql_passwd $APPD_ROOT
fi
