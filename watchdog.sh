#!/bin/bash
#
# $Id: watchdog.sh 3.0.1 2016-08-08 13:40:17 cmayer $
#
# watchdog.sh
# run on the passive node, fail over if we see the primary is very sick
# if we are not capable of failing over, fall over immediately
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
cd $(dirname $0)

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh

#
# this is needed to set the output of a pipe to the first failing process
#
set -o pipefail

#
# skip SSL certificate validation when doing health checks, ( useful for 
# self-signed certificates, and certs issued by internal, corporate CAs )
# leave empty to require certificate validation against the host's CA cert bundle
#
CERT_VALIDATION_MODE="-k"

# get all of the ports the controller listens on and determine the accompanying
# protocols
declare -a APP_PORT
declare -a APP_PROTO

IFS=$'\n'

i=0
for n in $( echo "cat /domain/configs/config[@name='server-config']/network-config/network-listeners/network-listener[@name!='admin-listener' and @name!='controller-config-listener']" | \
	xmllint --shell $DOMAIN_XML | grep \<network-listener ) ; do
	APP_PORT[$i]=$(echo "$n" | sed -re 's/^.*port="([0-9]+)".*$/\1/')
	protocol_name=$(echo "$n" | sed -re 's/^.*protocol="([^"]+)".*$/\1/')
	
	if echo "cat /domain/configs/config[@name='server-config']/network-config/protocols/protocol[@name='$protocol_name']/attribute::security-enabled" | xmllint --shell $DOMAIN_XML | grep -q 'security-enabled="true"' ; then
		APP_PROTO[$i]=https
	else
		APP_PROTO[$i]=http
	fi
	((i++))
done
IFS=\ 


#
# these are derived, but should not need editing
#
WATCHDOG_ERROR=$APPD_ROOT/logs/watchdog.error
SQL_ERROR=$WATCHDOG_ERROR

#
# hack to supppress password
#

wd_log=$APPD_ROOT/logs/watchdog.log
wd_tmp=/tmp/wd_curl.out.$$

# 
# These are the default timeouts, in seconds, before the watchdog will
# initiate a failover.  If they are set to low, they can cause unexpected
# failover events and controller downtime.  The following defaults are very
# conservative and should be overridden with site-specific settings in
# $APPD_ROOT/HA/watchdog.settings

# Controller app server not reachable via HTTP(S):  5 Minutes
DOWNLIMIT=300

# Controller app server shutting down: 5 Minutes
FALLINGLIMIT=300

# Controller app server starting up: 60 Minutes
RISINGLIMIT=3600

# The primary database is not responding: 5 Minutes
DBDOWNLIMIT=300

# The primary database cannot create a table: 2 Minutes
DBOPLIMIT=300

# The active controller host is not responding to ICMP echo, (ping),
# requests: 5 Minutes
PINGLIMIT=300

#
# the length of time to wait for a sql statememt to run
DBWAIT=10

#
# polling frequency
#
LOOPTIME=10

#
# Time to wait for a ping response
#
PINGTIME=2

#
# Time for curl to wait for a complete response from the controller
#
CURL_MAXTIME=2

#
# Time to wait between consecutive requests to create a dummy table on remote
#
DB_CREATE_DELAY=10

#
# overrides, so we don't have to edit this file
#
if [ -f $WATCHDOG_SETTINGS ] ; then
	source $WATCHDOG_SETTINGS
fi

last_db_create=0

#
# remove the watchdog pid and temporary curl output file when we exit
#
function cleanup {
	logmsg "watchdog exit" `date`
	rm -f $WATCHDOG_PID $wd_tmp $DELFILES
}

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
function sanity {
	check_sanity

	#
	# we must be the passive node
	#
	mode=`get_replication_mode localhost`
	if [ "$mode" == "active" ] ; then
		fatal 2 "this script must be run on the passive node"
	fi

	#
	# the replication slave must be running
	#
	slave=`sql localhost "show slave status" | wc -l`
	if [ "$slave" = 0 ] ; then
		fatal 3 "replication is not running"
	fi

	#
	# replication must be moderately healthy - it's ok if the primary is down
	#
	eval `get_slave_status`
	if [ "$slave_sql" != "Yes" ] ; then
		fatal 4 "slave SQL not running - replication error"
	fi
	case "$slave_io" in 
		"Yes")
			primary_up=true
			;;
		"Connecting")
			primary_up=false
			message "Primary DB not running"
			;;
		"No")
			primary_up=false
			fatal 8 "Slave IO not running"
			;;
		*)
			fatal 5 "Unrecognized state for slave IO: $slave_io"
			;;
	esac
}

#
# code to do a rest call for status. 
#
function serverstatus {
	local app_proto=$1
	local app_port=$2
	STATUS="$app_proto://$primary:$app_port/controller/rest/serverstatus"
	curl -m $CURL_MAXTIME -fsS $CERT_VALIDATION_MODE $STATUS > $wd_tmp 2>&1
	curlstat=$?
	case "$curlstat" in
	0)
		echo good
		;;
	7)
		echo "down"
		logmsg "curl error 7"
		;;
	22)
		eval `awk '/(22)/ {printf("http_code=%d\n", $8);}' < $wd_tmp`
		logmsg "curl error 22: $http_code"
		cat $wd_tmp | logonly
		case $http_code in
		503)
			echo "falling"
			;;
		500)
			echo "rising"
			;;
		404)
			echo "rising"
			;;
		*)
			echo "other"
			;;
		esac
		;;
	28)
		echo "down"
		logmsg "curl error 28: operation timed out"
		;;
	35)
		echo "down"
		logmsg "curl error 35"
		;;
	52)
		echo "no data"
		logmsg "curl error 52"
		;;
	*)
		echo "other"
		logmsg "curl error $curlstat"
		;;
	esac
}

#
# pass the variable, and limit
#
# warning: gnarly shell syntax and usage
#
function expired {
	if [ ${!1} -eq 0 ] ; then
		eval "$1=`date +%s`"
	fi
	now=`date +%s`
	limit=$((${!1} + $2))
	left=$(($limit - $now))
	logmsg `date` "expired $1 ${!1} $limit $left $2"
	echo "   timer $1 start $limit left $left limit $2" > $WATCHDOG_STATUS
	if [ `date +%s` -gt $((${!1} + $2)) ] ; then
		return 0
	else
		return 1
	fi
}

#
# our exceptional state loop
# 
# here is where we test primary health and return when something happens
# for long enough
function poll {
	local i=0

	downtime=0
	risingtime=0
	fallingtime=0
	pingfail=0
	dbfail=0
	dbopfail=0

	rm -f $WATCHDOG_STATUS

	while true ; do
		#
		# if somebody removed the watchdog file, stop watching
		#
		if [ ! -f $WATCHDOG_ENABLE ] ; then
			logmsg "watchdog newly disabled"
			return 0
		fi
		
		#
		# first, ping the primary.  
		# occasionally, ICMP is disabled, so PING can be disabled
		#
		if [ "$PINGLIMIT" = "0" ] ; then
			pingfail=0
		else
			if ping -c 1 -W $PINGTIME -q $primary >/dev/null 2>&1 ; then
				pingfail=0
			else
				if expired pingfail $PINGLIMIT ; then
					logmsg `date` pingfail expired
					return 2
				fi
				# we can't even ping.  Sleep for $((LOOPTIME-PINGTIME)) then try again
				sleep $((LOOPTIME-PINGTIME))
				continue
			fi
		fi

		#
		# then, is the primary database up listening
		#
		if $MYSQLADMIN --host=$primary "${CONNECT[@]}" ping >/dev/null 2>&1 ; then
			dbfail=0
		else
			dbopfail=0
			downtime=0
			risingtime=0
			fallingtime=0
			pingfail=0
			if expired dbfail $DBDOWNLIMIT ; then
				logmsg `date` dbfail expired
				return 2
			fi
			sleep $LOOPTIME
			continue
		fi

		#
		# then, is the database capable of doing some real work for us
		# only do this every DB_CREATE_DELAY
		#
		if [ $(($last_db_create+$DB_CREATE_DELAY)) -le `date +%s` ] ; then
			last_db_create=`date +%s`
			if \
				sql $primary "drop table if exists watchdog_test_table;" $DBWAIT &&
				sql $primary "create table watchdog_test_table (i int);" $DBWAIT &&
				sql $primary "insert into watchdog_test_table values (1);" $DBWAIT &&
				sql $primary "select count(*) from watchdog_test_table;" $DBWAIT >/dev/null 2>&1 &&
				sql $primary "drop table watchdog_test_table;" $DBWAIT ; then
				dbopfail=0
			else
				dbfail=0
				downtime=0
				risingtime=0
				fallingtime=0
				pingfail=0
				if expired dbopfail $DBOPLIMIT ; then
					logmsg `date` dbopfail expired
					return 2
				fi
				sleep $LOOPTIME
				continue
			fi
		fi

		#
		# how does the appserver respond to a serverstatus REST?
		# if down, try every port before calling expired
		#
		status=`serverstatus ${APP_PROTO[$i]} ${APP_PORT[$i]}`
		case $status in
		down)
			if [ $i -lt $((${#APP_PROTO[@]}-1)) ] ; then
				((i++))
				continue
			else
				i=0
			fi
			risingtime=0
			fallingtime=0
			pingfail=0
			dbfail=0
			dbopfail=0
			if expired downtime $DOWNLIMIT ; then
				logmsg `date` downtime expired
				return 2
			fi
			;;
		rising)
			# reset the other timers
			downtime=0
			fallingtime=0
			pingfail=0
			dbfail=0
			dbopfail=0

			if expired risingtime $RISINGLIMIT ; then
				logmsg `date` risingtime expired
				return 2
			fi
			;;
		falling)
			downtime=0
			risingtime=0
			pingfail=0
			dbfail=0
			dbopfail=0
			if expired fallingtime $FALLINGLIMIT ; then
				logmsg `date` fallingtime expired
				return 2
			fi
			;;
		good)
			return 0
			;;
		*)
			logmsg `date` "unknown status $status"
			return 1
			;;
		esac
		
		sleep $LOOPTIME
	done
}

#
# only run one watchdog
#
if [ -f "$WATCHDOG_PID" ] ; then
	WATCHPID=`cat $WATCHDOG_PID`
	if [ ! -z "$WATCHPID" ] ; then
		if kill -0 $WATCHPID 2>/dev/null ; then
			message "watchdog already running"
			exit 1
		fi
	fi
fi

#
# we are starting to run. register
#
trap cleanup EXIT
rm -f $WATCHDOG_PID
echo $$ > $WATCHDOG_PID

#
# force first report
#
laststatus=1

#
# our main loop.  every time the controller is noted up, we start from scratch.
#
while true ; do
	if [ ! -f $LOGFILE ] ; then
		logmsg "watchdog log" `date`
		logmsg "settings: down:$DOWNLIMIT falling:$FALLINGLIMIT \
 rising:$RISINGLIMIT dbdown:$DBDOWNLIMIT dbop:$DBOPLIMIT ping:$PINGLIMIT loop:$LOOPTIME"
	fi

	#
	# the watchdog enable file must exist.
	#
	if [ ! -f $WATCHDOG_ENABLE ] ; then
		fatal 1 "watchdog disabled"
	fi

	sanity

	poll
	pollstatus=$?
	case $pollstatus in
	0)
		# don't report consecutive good to minimize noise
		if [ $laststatus != '0' ] ; then
			logmsg "watchdog good" `date`
		fi
		;;
	2)
		logmsg "failover invoked" `date`
		$APPD_ROOT/HA/failover.sh -f &
		exit 0
		;;
	1|*)
		logmsg "watchdog abort poll status = $pollstatus" `date`
		exit 1
		;;
	esac
	sleep $LOOPTIME
	laststatus=$pollstatus
done

#
# script end
#
