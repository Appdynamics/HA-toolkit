#!/bin/bash
#
# $Id: assassin.sh 2.6 2015-09-02 15:36:05 cmayer $
#
# assassin.sh
# run on the active node after a failover, 
# this shoots down any secondary controller to prevent two actives 
# from showing up at the load balancer - we won't have any data integrity \
# problems, since replication is off
# 

# comment out to print logging messages to STDOUT
silence=">/dev/null"

#
# this may need editing to conform with your controller install
#
dbuser=root
APPD_ROOT=$( cd $(dirname "$0"); cd .. ; pwd)
dbpasswd=`cat $APPD_ROOT/db/.rootpw`
dbport=`grep ^DB_PORT $APPD_ROOT/bin/controller.sh | cut -d = -f 2`

#
# these are derived, but should not need editing
#
MYSQL="$APPD_ROOT/db/bin/mysql"
DBCNF="$APPD_ROOT/db/db.cnf"
CONNECT="--protocol=TCP --user=$dbuser --password=$dbpasswd --port=$dbport"
ASSASSIN=$APPD_ROOT/HA/appd_assassin.pid

#
# hack to supppress password
#
PWBLOCK='sed -e s/\(--password=\)[^-]*/\1=XXX/'

as_log=$APPD_ROOT/logs/assassin.log

if [ -f /sbin/service ] ; then
    service_bin=/sbin/service
elif [ -f /usr/sbin/service ] ; then
    service_bin=/usr/sbin/service
else
    echo service not found in /sbin or /usr/sbin - exiting
    exit 1
fi

# execute remote service operation
# args:  flags machine service verb
function remservice {
	if [ `id -u` == 0 ] ; then
		ssh $1 $2 $service_bin $3 $4
	else
		if ssh $2 [ -x /sbin/appdservice ] ; then
			ssh $1 $2 /sbin/appdservice $3 $4
		else
			ssh $1 $2 sudo -n $service_bin $3 $4
		fi
	fi
}

function sql {
	echo "$2 | $MYSQL --host=$1 $CONNECT controller" | $PWBLOCK >> $as_log
	echo "$2" | $MYSQL --host=$1 $CONNECT controller 2>> $as_log | tee -a $as_log
}

echo "  -- assassin log" `date` >> $as_log

#
# we do a boatload of sanity checks, and if anything is unexpected, we
# exit with a non-zero status and complain.
#
if [ ! -d "$APPD_ROOT" ] ; then
	echo controller root $APPD_ROOT is not a directory | tee -a $as_log $silence
	exit 1
fi
if [ ! -w "$APPD_ROOT/db/db.cnf" ] ; then
	echo db configuration $APPD_ROOT/db is not a directory | tee -a $as_log $silence
	exit 1
fi
if [ ! -x "$MYSQL" ] ; then
	echo controller root $MYSQL is not executable | tee -a $as_log $silence
	exit 1
fi

#
# we must be the active node
#
mode=`sql localhost \
 "select * from global_configuration_local where name = 'appserver.mode'\G" |
 awk '/value:/ { print $2}'`
if [ "$mode" == "passive" ] ; then
	echo "this script must be run on the active node" | tee -a $as_log $silence
	exit 1
fi

#
# if we are the 'marked primary', the assassin is not needed any more
#
type=`sql localhost \
 "select * from global_configuration_local where name = 'ha.controller.type'\G" |
 awk '/value:/ { print $2}'`
if [ "$type" == "primary" ] ; then
	echo "assassin unneeded" | tee -a $as_log $silence
	exit 1
fi

#
# replication must be not be enabled.  there are several markers for this:  
# skip-slave start is set in out db.cnf
# the slave is not running
if ! grep -q "^skip-slave-start=true" $DBCNF ; then
	echo slave not disabled | tee -a $as_log $silence
	exit 1
fi
primary=unset
eval `sql localhost "show slave status\G" | awk '
	BEGIN { OFS="" }
    /Slave_IO_Running:/ {print "slave_io=",$2}
    /Slave_SQL_Running:/ {print "slave_sql=",$2}
    /Master_Host:/ {print "primary=",$2}
'`
if [ "$slave_sql" != "No" ] ; then
	echo slave SQL running | tee -a $as_log $silence
	exit 1
fi
if [ "$slave_io" != "No" ] ; then
	echo slave IO running | tee -a $as_log $silence
	exit 1
fi
if [ "$primary" == "unset" ] ; then
	echo "replication not set up - primary unset" | tee -a $as_log $silence
	exit 1
fi
	
#
# ok, now we know that we are a failed-over primary, and there may be an
# old primary that may re-appear.  if it does, shoot it, and kick it hard 
# so it stays down.
#

echo "assassin committed" | tee -a $as_log $silence

echo $$ >$ASSASSIN

loops=0
while true ; do
	if [ $loops -gt 0 ] ; then
		sleep 60;
	fi
	(( loops ++ ))

	#
	# if the database becomes primary, we don't need to run anymore.
	#
	type=`sql localhost \
		 "select * from global_configuration_local where name = 'ha.controller.type'\G" | awk '/value:/ { print $2}'`
	if [ "$type" == "primary" ] ; then
		echo "assassin disabled" | tee -a $as_log $silence
		exit 1
	fi

	# if we can't get through, no point doing real work
	if ! ssh $primary date >/dev/null 2>&1 ; then
		continue;
	fi

	# make sure skip-slave-start is in db.cnf
	cat <<- 'DISABLE' | ssh $primary ed -s $DBCNF >/dev/null 2>&1
		g/^skip-slave-start/d
		$a
		skip-slave-start=true
		.
		wq
	DISABLE
	if ! ssh $primary grep -q skip-slave-start $DBCNF ; then
		echo "skip-slave-start insert failed" | tee -a $as_log $silence
		continue;
	fi

	# update the remote database
	sql $primary "stop slave;" >/dev/null
	sql $primary "update global_configuration_local set value='passive' where name = 'appserver.mode';" >/dev/null
	sql $primary "update global_configuration_local set value='secondary' where name = 'ha.controller.type';" >/dev/null

	# check if this happened
	if ! sql $primary "select value from global_configuration_local where name = 'appserver.mode';" | grep -q passive ; then
		echo "set passive failed" | tee -a $as_log $silence
		continue;
	fi

	echo "  -- disable slave autostart on $primary" >> $as_log
	remservice -tq $primary appdcontroller-db stop >> $as_log 2>&1

	sql localhost "update global_configuration_local set value='primary' where name = 'ha.controller.type';"
	echo "assassin exiting - old primary killed" >> $as_log
	rm -f $ASSASSIN
	exit 0

done

#
# script end
#

