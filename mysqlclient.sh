#!/bin/bash
#
# $Id: mysqlclient.sh 3.13 2017-10-21 00:47:23 rob.navarro $
#
# trivial command that executes sql for us.  this is intended
# to be invoked from an init script via runuser, so we can log
# output the rows as key-value pairs
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

LOGFNAME=mysqlclient.log

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh

terminal=false
if [ -t 0 ] ; then
	terminal=true
fi
mysqlopts=-EB

while getopts "ctr::" flag; do
	case $flag in
	t)
		terminal=true
		;;
	c)
		mysqlopts=
		;;

	r)	mysqlopts="$(tr ',' ' ' <<< "$OPTARG")"
		;;

	*)
		echo "usage: $0 <options>"
		echo "    [ -t ] interactive"
		echo "    [ -c ] compatible with controller-sh login-db"
		echo "    [ -r -s,-C ] raw comma separated MySQL client options"
		exit 0
		;;
	esac
done
shift $(( $OPTIND - 1 ))

if $terminal ; then
	$MYSQL -A $mysqlopts --host=localhost "${CONNECT[@]}" controller
	exit 0
fi

SQL=/tmp/mysqlclient.$$.sql
RESULT=/tmp/mysqlclient.$$.result
ERR=/tmp/mysqlclient.$$.err

cat > $SQL
$MYSQL $mysqlopts --host=localhost "${CONNECT[@]}" controller 2> $ERR 1> $RESULT < $SQL
RETC=$?

if [ -f $APPD_ROOT/HA/LOG_SQL ] ; then
	echo "mysqlclient: " `date` >> $LOGFILE
	cat $SQL >> $LOGFILE
	echo "result:" >> $LOGFILE
	cat $ERR $RESULT >> $LOGFILE
fi

[[ -s "$ERR" ]] && cat $ERR
[[ -s "$RESULT" ]] && cat $RESULT

rm -f $RESULT $SQL $ERR
exit $RETC
