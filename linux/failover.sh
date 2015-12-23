#!/bin/bash
#
# $Id: failover.sh 2.12 2015-12-23 00:36:28 cmayer $
#
# failover.sh
# run on the passive node, activate this HA node.
# 
# if run with the -f option, force failover
#
# this may need editing to conform with your controller install
#
dbuser=root
APPD_ROOT=$( cd $(dirname "$0"); cd .. ; pwd)
dbpasswd=`cat $APPD_ROOT/db/.rootpw`
dbport=`grep ^DB_PORT $APPD_ROOT/bin/controller.sh | cut -d = -f 2`
WATCHDOG=$APPD_ROOT/HA/appd_watchdog.pid

#
# these are derived, but should not need editing
#
MYSQL="$APPD_ROOT/db/bin/mysql"
DBCNF="$APPD_ROOT/db/db.cnf"
CONNECT="--protocol=TCP --user=$dbuser --password=$dbpasswd --port=$dbport"
#
# hack to supppress password
#
PWBLOCK='sed -e s/\(--password=\)[^-]*/\1=XXX/'

if [ -f /sbin/service ] ; then
    service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
    service_bin=/usr/sbin/service
else
    echo service not found in /sbin or /usr/sbin - exiting
    exit 13
fi

fo_log=$APPD_ROOT/logs/failover.log

#
# worker function for sql timer
#
function sqltimeout {
        if [ $sqlpid -ne 0 ] ; then
                echo "killing sql pid $sqlpid"
                disown $sqlpid
                kill -9 $sqlpid
                sqlpid=0
                sqlkiller=0
        fi
}

#
# args:  hostname command [ timeout ]
# sql wrapper - knows about timeout - returns 0 on success, nonzero otherwise
#
function sql {
		echo sql $1 "$2" $3 >> $fo_log
        if [ $# -lt 3 ] ; then
                echo "$2" | $MYSQL --host=$1 $CONNECT controller
        else
                trap sqltimeout SIGALRM
                tmpfile=/tmp/failover.sql.$$
                rm -f $tmpfile
                DELFILES=$tmpfile
                mypid=$$
                (sleep $3 ; kill -SIGALRM $mypid) &
                sqlkiller=$!
                disown $sqlkiller
                echo "$2" | $MYSQL --host=$1 $CONNECT controller > $tmpfile &
                sqlpid=$!
                wait $sqlpid
                retval=$?
                if [ $sqlkiller -ne 0 ] ; then
                        kill -9 $sqlkiller
                fi
                cat $tmpfile
                rm -f $tmpfile
                DELFILES=
                return $retval
        fi
}

function bounce_slave {
	sql localhost "stop slave ; start slave ;" >> $fo_log
}

function slave_status {
	bounce_slave

	# wait for the slave to settle
	connect_count=0

	while [ $connect_count -lt 3 ] ; do
		eval `sql localhost "show slave status\G" | awk '
			BEGIN { OFS="" }
			/Slave_IO_Running:/ {print "slave_io=",$2}
			/Slave_SQL_Running:/ {print "slave_sql=",$2}
			/Seconds_Behind_Master:/ {print "seconds_behind=",$2}
			/Master_Host:/ {print "primary=",$2}
		'`
		case "$slave_io" in
		Connecting) 
			(( connect_count++ ))
			sleep 10
			continue;
			;;
		Yes) break
			;;
		No) break
			;;
		esac
	done
}

# abstract out the privilege escalation
if [[ `id -u` == 0 ]] ; then
	function service {
		$service_bin $1 $2
	}

	function remservice {
		ssh $1 $2 $service_bin $3 $4
	}	
else
	if [ -x /sbin/appdservice ] ; then
		function service {
			/sbin/appdservice $1 $2
		}
		function remservice {
			ssh $1 $2 /sbin/appdservice $3 $4
		}	
	else
		function service {
			sudo $service_bin $1 $2
		}
		function remservice {
			ssh $1 $2 sudo $service_bin $3 $4
		}	
	fi
fi

#
# parse arguments
#
force=false

while getopts f flag; do
	case $flag in
	f)
		force=true
		;;
	*)
		echo "usage: $0 <options>"
		echo "    [ -f ] force replication break"
		exit
		;;
	esac
done

echo "  -- failover log" `date` >> $fo_log

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
if [ ! -d "$APPD_ROOT" ] ; then
	echo controller root $APPD_ROOT is not a directory | tee -a $fo_log
	exit 1
fi
if [ ! -w "$APPD_ROOT/db/db.cnf" ] ; then
	echo db configuration $APPD_ROOT/db is not a directory | tee -a $fo_log
	exit 1
fi
if [ ! -x "$MYSQL" ] ; then
	echo controller root $MYSQL is not executable | tee -a $fo_log
	exit 1
fi

#
# we must be the passive node
#
echo "  -- Verify passive node" | tee -a $fo_log
mode=`sql localhost \
 "select * from global_configuration_local where name = 'appserver.mode'\G" |
 awk '/value:/ { print $2}'`
if [ "$mode" == "active" ] ; then
	echo "this script must be run on the passive node" | tee -a $fo_log
	exit 1
fi

#
# we must be replicating
#
echo "  -- Verify replication state" | tee -a $fo_log
slave=`sql localhost \ "show slave status\G" | wc -l`
if [ "$slave" = 0 ] ; then
	echo "replication is not running" | tee -a $fo_log
	if [ $force != "true" ] ; then
		exit 1
	else
		echo "  -- Force Failover even with no slave" | tee -a $fo_log
		primary_up=false
	fi
fi

#
# replication must be moderately healthy - it's ok if the other server is down
#
slave_status
if [ "$slave_sql" != "Yes" ] ; then
	echo slave SQL not running - replication error | tee -a $fo_log
	if [ $force != "true" ] ; then
		exit 1
	else
		echo "  -- Force Failover - stopped slave" | tee -a $fo_log
		primary_up=false
	fi
fi
case "$slave_io" in 
	"Yes")
		primary_up=true
		;;
	"Connecting")
		primary_up=false
		echo "  -- Primary DB not running" | tee -a $fo_log
		;;
	*)
		echo "Unrecognized state for slave IO: $slave_io" | tee -a $fo_log
		if [ "$force" != true ] ; then
			exit 1
		else
			echo "  -- Force Failover - unknown slave state" | tee -a $fo_log
			primary_up=false
		fi
		;;
esac

#####
#
# at this point, we are committed to failing over
#

#
# kill the local watchdog if it is up
#
kc=0
while [ -f $WATCHDOG ] ; do
	if [ $(($kc % 10)) -eq 0 ] ; then
		kill `cat $WATCHDOG` >/dev/null 2>&1
		echo "  -- Kill Watchdog" | tee -a $fo_log
	fi
	let kc++
	sleep 1
done

#
# kill the local appserver if it's running
#
echo "  -- Kill Local Appserver" | tee -a $fo_log
service appdcontroller stop >> $fo_log 2>&1

#
# persistently break replication if the primary is down, 
# or we want to force a replication break
#
if [ "$force" == true -o "$primary_up" == false ] ; then
	echo "  -- Disable local slave autostart" | tee -a $fo_log

	#
	# disable automatic start of replication slave
	# edit the db.cnf to remove any redundant entries for skip-slave-start
	# this is to ensure that replication does not get turned on by a reboot
	#
	ex -s $DBCNF <<- 'DISABLE'
g/^skip-slave-start/d
$a
skip-slave-start=true
.
wq
DISABLE
	#
	# now stop the replication slave
	#
	echo "  -- Stop local slave " | tee -a $fo_log
	sql localhost "stop slave;"
fi

#
# if the primary is up, mark it passive, and stop the appserver
# also, if the old primary is not reachable, ha.controller.type will be changed by the assassin when it finally makes contact.
#
if [ "$primary_up" = "true" ] ; then
	echo "  -- Stop primary appserver" | tee -a $fo_log
	remservice -tq $primary appdcontroller stop >> $fo_log 2>&1
	echo "  -- Mark primary passive + secondary" | tee -a $fo_log
	if sql $primary "update global_configuration_local set value='passive' where name = 'appserver.mode';" 10 &&
sql $primary "update global_configuration_local set value='secondary' where name = 'ha.controller.type';" 10 ; then
		echo "  -- Mark local primary" | tee -a $fo_log
		sql localhost "update global_configuration_local set value='primary' where name = 'ha.controller.type';"
	else
		echo "  -- Primary DB timeout" | tee -a $fo_log
		break_replication=true
	fi
	if [ "$break_replication" == true ] ; then
		primary_up=false
		echo "  -- Stop secondary database" | tee -a $fo_log
		remservice -tq $primary appdcontroller-db stop >> $fo_log 2>&1
		ssh -tq $primary ex -s $DBCNF <<- 'DISABLEP'
g/^skip-slave-start/d
$a
skip-slave-start=true
.
wq
DISABLEP
	fi
fi

#
# the primary is now down and maybe passive; 
# it is now safe to mark our node active and start the appserver
#
echo "  -- Mark local active" | tee -a $fo_log
echo "  -- Starting local Controller" | tee -a $fo_log
sql localhost "update global_configuration_local set value='active' where name = 'appserver.mode';"
#
# this will start the assassin if needed.
service appdcontroller start >> $fo_log 2>&1

#
# if the other side was ok, then we can start the service in passive mode
#
if [ "$primary_up" = "true" ] ; then
	echo "  -- start passive secondary" | tee -a $fo_log
	remservice -nqf $primary appdcontroller start | tee -a $fo_log 2>&1 &
fi

echo "  -- Failover complete" | tee -a $fo_log

exit 0
#
# script end
#

