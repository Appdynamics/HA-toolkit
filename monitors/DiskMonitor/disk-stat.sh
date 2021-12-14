#!/bin/bash 
# 
# Monitors Disks on Linux 
# 
# $Id: disk-stat.sh 3.21 2021-01-02 cmayer $
# 
# using only: iostat, awk
# 
# Copyright 2021 AppDynamics, Inc 
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

#
# this version is tolerant of varying iostat column order, presence and names
#
iostat -xdk 1 | awk ' 
BEGIN {
	# column translation array indexed by heading
	trans["r/s"]="reads per sec"
	trans["w/s"]="writes per sec"
	trans["rkB/s"] = "reads (kb/s)"
	trans["wkB/s"] = "writes (kb/s)"
	trans["aqu-sz"] = "avg queue length"
	trans["avgqu-sz"] = "avg queue length"
	trans["await"] = "avg wait (ms)"
	trans["rareq-sz"] = "avg read size (k)"
	trans["r_await"] = "avg read await (ms)"
	trans["wareq-sz"] = "avg write size (k)"
	trans["w_await"] = "avg write await (ms)"
	trans["svctm"] = "service time (ms)"
}

/Device/ { 
	reports++
	if (reports > 1) next
	# process heading and link output fields to actual fields
	for (col = 2; col <= NF; col++) {
		if ($col in trans) {
			colname[col] = trans[$col];
		}
	}
	next
}

# ignore the first cumulative report
(reports > 1) {
	# scan through columns with names
	for (col = 2; col <= NF; col++) {
		if (!colname[col]) continue;
		printf("name=Hardware Resources|Disk|%s|%s,aggregator=AVERAGE,value=%d\n", 
			$1, colname[col], $col);
	}
}'
