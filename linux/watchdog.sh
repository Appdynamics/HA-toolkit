#!/bin/bash
#
# $Id: watchdog.sh,v 2.6 2015/03/17 01:24:29 cmayer Exp $
#
# watchdog.sh
# run on the passive node, fail over if we see the primary is very sick
# if we are not capable of failing over, fall over immediately

#
# skip SSL certificate validation when doing health checks, ( useful for 
# self-signed certificates, and certs issued by internal, corporate CAs )
# leave empty to require certificate validation against the host's CA cert bundle
#
CERT_VALIDATION_MODE="-k"

APPD_ROOT=$( cd $(dirname "$0"); cd .. ; pwd)
DOMAIN_XML=$APPD_ROOT/appserver/glassfish/domains/domain1/config/domain.xml

dbpasswd=`cat $APPD_ROOT/db/.rootpw`
dbport=`grep ^DB_PORT $APPD_ROOT/bin/controller.sh | cut -d = -f 2`

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

WATCHDOG=$APPD_ROOT/HA/appd_watchdog.pid
RUNUSER=`awk -F= '/^[\t ]*user=/ {print $2}' $APPD_ROOT/db/db.cnf`

#
# these are derived, but should not need editing
#
MYSQL="$APPD_ROOT/db/bin/mysql"
MYSQLADMIN="$APPD_ROOT/db/bin/mysqladmin"
DBCNF="$APPD_ROOT/db/db.cnf"
CONNECT="--protocol=TCP --user=root --password=$dbpasswd --port=$dbport"
WATCHDOG_ENABLE=$APPD_ROOT/HA/WATCHDOG_ENABLE
WATCHDOG_SETTINGS=$APPD_ROOT/HA/watchdog.settings
WATCHDOG_STATUS=$APPD_ROOT/logs/watchdog.status

fo_log=$APPD_ROOT/logs/failover.log
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

# The active controller host is not responding to ICMP echo, (ping),
# requests: 5 Minutes
PINGLIMIT=300

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
# remove the watchdog pid and temporary curl output file when we exit
#
function cleanup () {
	echo `date` "watchdog exit" >> $wd_log
	rm -f $WATCHDOG $wd_tmp
}

#
# logging local/remote sql wrapper
#
function sql {
	# echo "$2 | $MYSQL --host=$1 $CONNECT controller" >> $wd_log
	echo "$2" | $MYSQL --host=$1 $CONNECT controller
}

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
function sanity {
	if [ ! -d "$APPD_ROOT" ] ; then
		echo $APPD_ROOT is not a directory >> $wd_log
		return 0
	fi
	if [ ! -w "$APPD_ROOT/db/db.cnf" ] ; then
		echo $APPD_ROOT/db/db.cnf is not a directory >> $wd_log
		return 0
	fi
	if [ ! -x "$MYSQL" ] ; then
		echo controller root $MYSQL is not executable >> $wd_log
		return 0
	fi

	#
	# the watchdog enable file must exist.
	#
	if [ ! -f $WATCHDOG_ENABLE ] ; then
		echo watchdog disabled
		return 0
	fi

	#
	# we must be the passive node
	#
	mode=`sql localhost \
	 "select * from global_configuration_local where name='appserver.mode'\G" |
	 awk '/value:/ { print $2}'`
	if [ "$mode" == "active" ] ; then
		echo "this script must be run on the passive node" >> $wd_log
		return 0
	fi

	#
	# we must be replicating
	#
	slave=`sql localhost \ "show slave status\G" | wc -l`
	if [ "$slave" = 0 ] ; then
		echo "replication is not running" >> $wd_log
		return 0
	fi

	#
	# replication must be moderately healthy - it's ok if the primary is down
	#
	eval `sql localhost \ "show slave status\G" | awk '
		BEGIN { OFS="" }
		/Slave_IO_Running:/ {print "slave_io=",$2}
		/Slave_SQL_Running:/ {print "slave_sql=",$2}
		/Seconds_Behind_Master:/ {print "seconds_behind=",$2}
		/Master_Host:/ {print "primary=",$2}
	'`
	if [ "$slave_sql" != "Yes" ] ; then
		echo slave SQL not running - replication error >> $wd_log
		return 0
	fi
	case "$slave_io" in 
		"Yes")
			primary_up=true
			;;
		"Connecting")
			primary_up=false
			echo "  -- Primary DB not running" >> $wd_log
			;;
		*)
			echo "Unrecognized state for slave IO: $slave_io" >> $wd_log
			return 0
			;;
	esac
	return 1
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
		echo "curl error 7" >> $wd_log
		;;
	22)
		eval `awk '/(22)/ {printf("http_code=%d\n", $8);}' < $wd_tmp`
		echo "curl error 22: $http_code" >> $wd_log
		cat $wd_tmp >> $wd_log
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
		echo "curl error 28: operation timed out" >> $wd_log
		;;
	35)
		echo "down"
		echo "curl error 35" >> $wd_log
		;;
	52)
		echo "no data"
		echo "curl error 52" >> $wd_log
		;;
	*)
		echo "other"
		echo "curl error $curlstat" >> $wd_log
		;;
	esac
}

#
# pass the variable, and limit
#
# warning: gnarly shell syntax and usage
#
function expired () {
	if [ ${!1} -eq 0 ] ; then
		eval "$1=`date +%s`"
	fi
	now=`date +%s`
	limit=$((${!1} + $2))
	left=$(($limit - $now))
	echo `date` "expired $1 ${!1} $limit $left $2" >> $wd_log
	echo "expired $limit $left $2" > $WATCHDOG_STATUS
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
	rm -f $WATCHDOG_STATUS

	while true ; do
		#
		# if somebody removed the watchdog file, stop watching
		#
		if [ ! -f $WATCHDOG_ENABLE ] ; then
			echo watchdog newly disabled >> $wd_log
			return 0
		fi
		
		#
		# first, ping the primary
		#
		if ping -c 1 -W $PINGTIME -q $primary >/dev/null 2>&1 ; then
			pingfail=0
		else
			if expired pingfail $PINGLIMIT ; then
				echo `date` pingfail expired >> $wd_log
				return 2
			fi
			# we can't even ping.  Sleep for $((LOOPTIME-PINGTIME)) then try again
			sleep $((LOOPTIME-PINGTIME))
			continue
		fi
		
		#
		# then, is the database up
		#
		if $MYSQLADMIN $CONNECT ping >/dev/null 2>&1 ; then
			dbfail=0
		else
			if expired dbfail $DBLIMIT ; then
				echo `date` dbfail expired >> $wd_log
				return 2
			fi
		fi
		
		#
		# how does the appserver respond to a serverstatus REST?
		# if down, try every port before calling expired()
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
			if expired downtime $DOWNLIMIT ; then
				echo `date` downtime expired >> $wd_log
				return 2
			fi
			;;
		rising)
			if expired risingtime $RISINGLIMIT ; then
				echo `date` risingtime expired >> $wd_log
				return 2
			fi
			;;
		falling)
			if expired fallingtime $FALLINGLIMIT ; then
				echo `date` fallingtime expired >> $wd_log
				return 2
			fi
			;;
		good)
			return 0
			;;
		*)
			echo `date` "unknown status $status" >> $wd_log
			return 1
			;;
		esac
		
		sleep $LOOPTIME
	done
}

#
# begin actual code
#
if [ `id -un` != "$RUNUSER" ] ; then
	echo watchdog must run as $RUNUSER
	exit 1
fi

#
# only run one watchdog
#
if [ -f "$WATCHDOG" ] ; then
	WATCHPID=`cat $WATCHDOG`
	if [ ! -z "$WATCHPID" ] ; then
		if kill -0 $WATCHPID 2>/dev/null ; then
			echo watchdog already running
			exit 1
		fi
	fi
fi

#
# we are starting to run. register
#
trap cleanup EXIT
rm -f $WATCHDOG
echo $$ > $WATCHDOG

#
# overrides, so we don't have to edit this file
#
if [ -f $WATCHDOG_SETTINGS ] ; then
	source $WATCHDOG_SETTINGS
fi

#
# our main loop.  every time the controller is noted up, we start from scratch.
#
while true ; do
	echo "  -- watchdog log " `date` > $wd_log
	if sanity ; then
		if [ -f $WATCHDOG_ENABLE ] ; then
			echo "failover not possible" | tee -a $wd_log
		fi
		echo "watchdog exiting" | tee -a $wd_log
		exit 1
	fi

	echo "  -- settings: down:$DOWNLIMIT falling:$FALLINGLIMIT \
rising:$RISINGLIMIT dbdown:$DBDOWNLIMIT ping:$PINGLIMIT loop:$LOOPTIME" >> $wd_log

	poll
	pollstatus=$?
	date >> $wd_log
	case $pollstatus in
	0)
		echo "watchdog good" >> $wd_log
		;;
	2)
		echo "failover invoked" >> $wd_log
		$APPD_ROOT/HA/failover.sh >> $fo_log 2>&1 &
		exit 0
		;;
	1|*)
		echo "watchdog abort poll status = $pollstatus" >> $wd_log
		exit 1
		;;
	esac
	sleep $LOOPTIME
done

#
# script end
#
