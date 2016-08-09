#!/bin/bash
#
# Monitors INNODB
#
# $Id: mysql-stat.sh 3.0 2016-08-04 03:09:03 cmayer $
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
PATH=$PATH:/bin:/usr/sbin:/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

[ -f /etc/sysconfig/appdcontroller ] && . /etc/sysconfig/appdcontroller
[ -f /etc/default/appdcontroller ] && . /etc/default/appdcontroller

if [ -x $APPD_ROOT/HA/mysqlclient.sh ] ; then
	MYSQLCLIENT="$APPD_ROOT/HA/mysqlclient.sh"
else
	MYSQLCLIENT="$APPD_ROOT/bin/controller.sh login-db"
 fi 

while [ 1 ]; do
NEXTSECONDS=`date +%s | awk '{print $1 + 60}'`

echo "show engine innodb status\G" | $MYSQLCLIENT | awk '

	/^BUFFER POOL AND MEMORY/ { state = 1; }
	/^Database pages/ { if (state == 1) {
		bufcnt = $3; 
	}}
	/^Modified/ { if (state == 1) {
		dirty = $4;
	}}
	/^Old database pages/ { if (state == 1) {
		oldpages = $4;
	}}

	/^INDIVIDUAL BUFFER POOL INFO/ { state = 2; }

	/^TRANSACTIONS/ { state = 3; }
	/^History list length/ { if (state == 3) histlen = $4; }
	/^---TRANSACTION.*ACTIVE/ { if (state == 3) {
		xcount++;
		active = $4; if (active > hiwat) {hiwat = active}
	}}

	/^FILE I/ { state = 4; }
	/reads.*writes.*fsyncs/ { if (state == 4) {
		reads = $1; writes = $6; syncs = $8;
	}}

	/^LOG/ { state = 5; }
	/Log sequence number/ { if (state == 5) { logseq = $4}}
	/Log flushed up to/ { if (state == 5) { logflushed = $5}}
	/Last checkpoint at/ { if (state == 5) { logcheckpoint = $4}}
	/Max checkpoint age/ { if (state == 5) { maxcheckpointage = $4}}
	/Checkpoint age target/ { if (state == 5) { checkpointagetarget = $4}}
	/Modified age/ { if (state == 5) { modifiedage = $3}}
	/Checkpoint age/ { if (state == 5) { checkpointage = $3}}
	/pending log writes,.*pending chkp writes/ { if (state == 5) { pendinglog=$1; pendingckpt=$5 }}
	/log.*done.*log.*second/ { if (state == 5) {
		logio = $5;
	}}

	/^ROW OPERATIONS/ { state = 6; }
	/inserts.*updates.*deletes.*reads/ { if (state == 6) {
		inserts = $1; updates = $3; deletes = $5; rowreads = $7;
	}}

	END { 
		printf("name=Custom Metrics|Mysql|Buffers Used,aggregator=OBSERVATION,value=%d\n", bufcnt);
		printf("name=Custom Metrics|Mysql|Buffers Dirty,aggregator=OBSERVATION,value=%d\n", dirty);
		printf("name=Custom Metrics|Mysql|Buffers Old,aggregator=OBSERVATION,value=%d\n", oldpages);

		printf("name=Custom Metrics|Mysql|Transaction count,aggregator=OBSERVATION,value=%d\n", xcount);
		printf("name=Custom Metrics|Mysql|Transaction high time,aggregator=OBSERVATION,value=%d\n", hiwat);

		printf("name=Custom Metrics|Mysql|File reads,aggregator=OBSERVATION,value=%d\n", reads);
		printf("name=Custom Metrics|Mysql|File writes,aggregator=OBSERVATION,value=%d\n", writes);
		printf("name=Custom Metrics|Mysql|File syncs,aggregator=OBSERVATION,value=%d\n", syncs);

		printf("name=Custom Metrics|Mysql|Log seq number,aggregator=OBSERVATION,value=%d\n", logseq);
		printf("name=Custom Metrics|Mysql|Log flushed,aggregator=OBSERVATION,value=%d\n", logflushed);
		printf("name=Custom Metrics|Mysql|Log checkpoint,aggregator=OBSERVATION,value=%d\n", logcheckpoint);

		printf("name=Custom Metrics|Mysql|Log dirty,aggregator=OBSERVATION,value=%d\n", logseq - logflushed);
		printf("name=Custom Metrics|Mysql|Log used,aggregator=OBSERVATION,value=%d\n", logseq - logcheckpoint);

		printf("name=Custom Metrics|Mysql|Log max checkpoint age,aggregator=OBSERVATION,value=%d\n", maxcheckpointage);
		printf("name=Custom Metrics|Mysql|Log checkpoint age target,aggregator=OBSERVATION,value=%d\n", checkpointagetarget);
		printf("name=Custom Metrics|Mysql|Log modified age,aggregator=OBSERVATION,value=%d\n", modifiedage);
		printf("name=Custom Metrics|Mysql|Log checkpoint age,aggregator=OBSERVATION,value=%d\n", checkpointage);
		printf("name=Custom Metrics|Mysql|Log pending log writes,aggregator=OBSERVATION,value=%d\n", pendinglog);
		printf("name=Custom Metrics|Mysql|Log pending checkpoint writes,aggregator=OBSERVATION,value=%d\n", pendingckpt);
		printf("name=Custom Metrics|Mysql|Log io,aggregator=OBSERVATION,value=%d\n", logio);

		printf("name=Custom Metrics|Mysql|Row inserts,aggregator=OBSERVATION,value=%d\n", inserts);
		printf("name=Custom Metrics|Mysql|Row updates,aggregator=OBSERVATION,value=%d\n", updates);
		printf("name=Custom Metrics|Mysql|Row deletes,aggregator=OBSERVATION,value=%d\n", deletes);
		printf("name=Custom Metrics|Mysql|Row reads,aggregator=OBSERVATION,value=%d\n", rowreads);

	}
'

echo "show slave status\G" | $MYSQLCLIENT | awk '

	/Seconds_Behind_Master:/ { spm = $2; }

	END { 
		printf("name=Custom Metrics|Mysql|Slave Seconds Behind Master,aggregator=OBSERVATION,value=%d\n", spm);
	}
'
echo "select value from global_configuration_local where name = 'appserver.mode'\G" | $MYSQLCLIENT | awk '

	/value:/ { if ($2 == "active") active = 1; else active = 0; }

	END { 
		printf("name=Custom Metrics|Mysql|Appserver Active,aggregator=OBSERVATION,value=%d\n", active);
	}
'

SLEEPTIME=`date +"$NEXTSECONDS %s" | awk '{if ($1 > $2) print $1 - $2; else print 0;}'`
sleep $SLEEPTIME
done
