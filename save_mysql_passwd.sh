#!/bin/bash
#
# $Id: save_mysql_passwd.sh 3.14 2019-03-04 18:10:00 robnav $
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

LOGFNAME=save_mysql_passwd.log

. lib/log.sh
. lib/ha.sh
. lib/password.sh

if [ -x $APPD_ROOT/db/bin/mysql_config_editor ] ; then

	# MySQL bug: https://bugs.mysql.com/bug.php?id=74691 that silently accepts less
	# characters than entered by user after '#' character.
	# Note MySQL bug report shows delimiting single quote work-around
	# Note getpass source code: https://code.woboq.org/userspace/glibc/misc/getpass.c.html
	#  shows stdin opened if no /dev/tty available. Will use this.
	# Work-around with:
	# - separate and reliable password collection into a variable
	# - use setsid to disconnect controlling TTY from sub-process
	# - use Here string to setsid with single quotes around variable
	getpw _XYZ
	$APPD_ROOT/db/bin/mysql_config_editor reset
	setsid bash -c "$APPD_ROOT/db/bin/mysql_config_editor set --user=root -p 2>$LOGFNAME" <<< "'$_XYZ'"
else
	save_mysql_passwd $APPD_ROOT
fi
