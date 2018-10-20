#
# $Id: lib/sql.sh 3.32 2018-05-16 21:15:14 cmayer $
#
# run sql statements
# potentially logging, potentially with timeouts,
# outputting rows as key-value pairs
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

dbport=${dbport:-`dbcnf_get port`}

#
# these are derived, but should not need editing
#
MYSQL="$APPD_ROOT/db/bin/mysql"
MYSQLADMIN="$APPD_ROOT/db/bin/mysqladmin"
CONNECT=(--protocol=TCP --user=root --port=$dbport)
ACONNECT=(--host=localhost -p ${CONNECT[@]})		# mysqladmin specific without dbpasswd
dbpasswd=${dbpasswd:-`get_mysql_passwd`}		# used by mysqladmin regardless of .mylogin.cnf
if [[ ! -f $APPD_ROOT/db/.mylogin.cnf ]] ; then
	CONNECT+=("--password=$dbpasswd")
fi

#
# bunch of state variables
#
sqlpid=0
sqlkiller=0
sqlkilled=0
DELFILES=""

#
# alarm signal handler function for sql timer
#
function sqltimeout {
	echo "sqltimeout $sqlpid"
	if [ $sqlpid -ne 0 ] ; then
		echo "sql timed out: killing pid $sqlpid" | logonly
		disown $sqlpid
		kill -s SIGINT $sqlpid
		sqlpid=0
		sqlkiller=0
		sqlkilled=1
	fi
}

#
# sql wrapper - knows about timeout - returns 0 on success, nonzero otherwise
# args:  hostname command [ timeout ]
#
# side effects, is that it sends errors and sql to sqlerr
# sets DELFILES
#
function sql {
	local tmpfile
	local errfile
	local mypid
	local retval

	mypid=$$
	tmpfile=/tmp/sql_result.$mypid
	errfile=/tmp/sql-err.$mypid
	DELFILES="$tmpfile $errfile"
	rm -f $DELFILES

	if [ "$1" == localhost ] ; then
		COMMAND=($MYSQL -BE --host=localhost "${CONNECT[@]}" controller)
	else
		COMMAND=($SSH $1 $APPD_ROOT/HA/mysqlclient.sh)
	fi

	if [ $# -lt 3 ] ; then
		echo "$2" | "${COMMAND[@]}" > $tmpfile
		if [ -f $APPD_ROOT/HA/LOG_SQL ] ; then
			echo "${COMMAND[@]}" | logonly
			echo "$2" | logonly
			echo "result:" | logonly
			cat $tmpfile | logonly
		fi
		cat $tmpfile
	else
		trap sqltimeout SIGALRM
		# start time bomb
		sqlkilled=0
		(sleep $3 ; kill -SIGALRM $mypid) &
		sqlkiller=$!
		disown $sqlkiller

		# issue sql
		echo `date` "sql text: $2" >$errfile
		echo "$2" | "${COMMAND[@]}" >$tmpfile 2>>$errfile &
		sqlpid=$!
		wait $sqlpid
		retval=$?
		if [ $sqlkiller -ne 0 ] ; then
			kill -9 $sqlkiller >/dev/null 2>&1
		fi
		if [ $sqlkilled -ne 0 ] ; then
			echo "sqlkilled: ret $retval" >> $errfile
			retval=1
		fi

		if [ $retval == 0 ] ; then
			cat $tmpfile
        else
			echo "output: " >> $errfile
			cat $tmpfile >> $errfile
			cat $errfile | logonly
        fi
		return $retval
	fi
	rm -f $DELFILES
	DELFILES=""
}

#
# read a column from sql return
#
function get {
	local key=$1
	awk "/^[ \t]*$key:/ {print \$2}"
}

function get_replication_master {
    sql localhost "show slave status" 5 | get Master_Host
}

function get_replication_type {
	local host=$1
	sql $host "select value from global_configuration_local where name = \
		'ha.controller.type'" | get value
}

function get_replication_mode {
	local host=$1
	sql $host "select value from global_configuration_local where name = \
		'appserver.mode'" | get value
}

function bounce_slave {
    sql localhost "stop slave ; start slave ;"
}

function get_slave_status {
	slave_io=""
	slave_sql=""
	seconds_behind=""
	primary=""

	sql localhost "show slave status" | \
	awk 'BEGIN { OFS="" }
         /Slave_IO_Running:/ {print "slave_io=",$2}
         /Slave_SQL_Running:/ {print "slave_sql=",$2}
         /Seconds_Behind_Master:/ {print "seconds_behind=",$2}
         /Master_Host:/ {print "primary=",$2}'
}

