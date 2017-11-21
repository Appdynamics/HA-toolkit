#!/bin/bash
#
# $Id: assassin.sh 3.25 2017-06-29 17:19:20 cmayer $
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
# run on the active node after a failover, 
# this shoots down any secondary controller to prevent two actives 
# from showing up at the load balancer - we won't have any data integrity
# problems, since replication is off
# 
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

LOGFNAME=assassin.log

# source function libraries
. lib/log.sh
. lib/runuser.sh
. lib/conf.sh
. lib/ha.sh
. lib/password.sh
. lib/sql.sh
. lib/status.sh

message "assassin log" `date`
check_sanity

#
# we must be the active node
#
mode=`get_replication_mode localhost`
if [ "$mode" == "passive" ] ; then
	fatal 6 "this script must be run on the active node"
fi

#
# if we are the 'marked primary', the assassin is not needed any more
#
type=`get_replication_type localhost`
if [ "$type" == "primary" ] ; then
	message "assassin unneeded"
	exit 0
fi

if ! replication_disabled ; then
	fatal 5 "slave not disabled"
fi
primary=unset
eval `get_slave_status`
if [ "$slave_io" != "No" ] ; then
	fatal 8 "slave IO running"
fi
if [ "$primary" == "unset" ] ; then
	fatal 9 "replication not set up - primary unset"
fi
	
if assassin_running ; then
	echo "assassin already running"
	exit 1
fi

#
# ok, now we know that we are a failed-over primary, and there may be an
# old primary that may re-appear.  if it does, shoot it, and kick it hard 
# so it stays down.
#

message "assassin committed"

echo $$ >$ASSASSIN_PIDFILE

loops=0
while true ; do
	if [ $loops -gt 0 ] ; then
		sleep 60;
	fi
	(( loops ++ ))

	#
	# brutally shoot down the appserver, as we don't want to confuse the
	# load balancer.  this cannot wait.
	# 
	message "killing appserver unconditionally on $primary"
	ssh $primary pkill -9 -f ".*java .*appserver/glassfish"

	#
	# if the local database becomes primary, we don't need to run anymore.
	#
	type=`get_replication_type localhost`
	if [ "$type" == "primary" ] ; then
		message "assassin disabled"
		exit 0
	fi

	#
	# if we can't get through, no point doing real work for now. loop
	#
	if ! ssh $primary date >/dev/null 2>&1 ; then
		continue;
	fi

	#
	# make sure skip-slave-start is in db.cnf
	# this is to prevent log reads from the real primary if the db is restarted
	#
	dbcnf_set skip-slave-start true $primary
	if [ $(dbcnf_get skip-slave-start $primary) = unset ] ; then
		gripe "skip-slave-start insert failed"
		continue;
	fi

	#
	# as replication is broken, stop the DB - no point keeping it up
	#
	message "stop database on $primary"
	remservice -tq $primary appdcontroller-db stop | logonly 2>&1

	#
	# and stay down.  this prevents inadvertently starting anything.
	# re-run replication to allow startup.
	#
	message "persistently disabling appserver on $primary"
	ssh $primary mv -f $APPD_ROOT/bin/controller.sh \
		$APPD_ROOT/bin/controller.sh-disabled | logonly 2>&1
	ssh $primary chmod 0 $APPD_ROOT/bin/controller.sh-disabled | logonly 2>&1

	# 
	# now mark our job done
	#
	sql localhost "update global_configuration_local set value='primary' \
		where name = 'ha.controller.type';"
	message "assassin exiting - old primary killed"
	rm -f $ASSASSIN_PIDFILE
	exit 0

done
