#!/bin/bash
#
# Monitors Disks on Linux
#
# version 1.3
#
# using only: date, awk, sleep
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

MOUNTS=
# uncomment the next line to enable custom metrics for mounted filesystems
#MOUNTS=`mount| awk '/^\/dev/ {sub("/dev/","",$1);printf("%s:%s;",$1, $3)}'`
# uncomment the next line to enable custom metrics for swap
#MOUNTS+=`awk '/\/dev/ {sub("/dev/","",$1);printf("%s:swap;",$1)}'< /proc/swaps`

# interval between reads of network and disk numbers
SAMPLE=10

PATH=$PATH:/bin:/usr/sbin:/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin

while [ 1 ]; do
NEXTSECONDS=`date +%s | awk '{print $1 + 60}'`
iostat -x 2 2 | awk '
	/Device:/ { state ++; next }
	( NF == 12 && state == 2) { 
		agg="AVERAGE";
		dev = $1;
		printf("name=Hardware Resources|Disk|%s|avg req size,aggregator=%s,value=%d\n", dev, agg, $8);
		printf("name=Hardware Resources|Disk|%s|avg queue length,aggregator=%s,value=%d\n", dev, agg, $9);
		printf("name=Hardware Resources|Disk|%s|avg wait (us),aggregator=%s,value=%d\n", dev, agg, $10*1000);
		printf("name=Hardware Resources|Disk|%s|avg svctime (us),aggregator=%s,value=%d\n", dev, agg, $11*1000);
		printf("name=Hardware Resources|Disk|%s|utilization (us),aggregator=%s,value=%d\n", dev, agg, $12);
	}
'

SLEEPTIME=`date +"$NEXTSECONDS %s" | awk '{if ($1 > $2) print $1 - $2; else print 0;}'`
sleep $SLEEPTIME
done
