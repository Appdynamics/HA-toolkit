#!/bin/bash 
# 
# Monitors Numa on Linux 
# 
# $Id: numa-stat.sh 3.27 2017-08-10 09:29:00 cmayer $
# 
# Copyright 2017 AppDynamics, Inc 
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
# http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
#

PATH=$PATH:/bin:/usr/sbin:/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

# seconds between samples - 5 minutes here
INTERVAL=$(( 5 * 60 ))

LASTPULSE=0

while [ 1 ]; do
NEXTSECONDS=`date +%s | awk '{print $1 + 60}'`

PULSE=$(($(date +%s) / $INTERVAL))
if [ $PULSE != $LASTPULSE ] ; then
	LASTPULSE=$PULSE

# get general statistics
stats=$(numastat -m | awk '
	function do_stat() {
		for (node = 0 ; node < NF - 1; node++) {
			col=node+2;
			nodename="Node " node;
			if (col == NF) nodename="Total";
			printf("name=Custom Metrics|Numa|%s|%s,aggregator=OBSERVATION,value=%d\n", nodename, $1, $col);
		}
	}
	/MemTotal/ { do_stat(); }
	/MemFree/  { do_stat(); }
	/MemUsed/  { do_stat(); }
')
fi

echo "$stats"

SLEEPTIME=`date +"$NEXTSECONDS %s" | awk '{if ($1 > $2) print $1 - $2; else print 0;}'`
sleep $SLEEPTIME
done
