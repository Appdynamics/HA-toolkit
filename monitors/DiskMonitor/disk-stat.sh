#!/bin/bash 
# 
# Monitors Disks on Linux 
# 
# $Id: disk-stat.sh 3.20 2017-06-02 15:05:40 cmayer $
# 
# using only: iostat, awk
# 
# Copyright 2016 AppDynamics, Inc 
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

iostat -xk 1 | awk ' 
/Device:/ { state ++; next }
( NF == 12 && state >= 2) { 
   state=2;
   agg="AVERAGE"; 
   dev = $1; 
   printf("name=Hardware Resources|Disk|%s|avg req size (s),aggregator=%s,value=%d\n", dev, agg, $8); 
   printf("name=Hardware Resources|Disk|%s|avg queue length,aggregator=%s,value=%d\n", dev, agg, $9); 
   printf("name=Hardware Resources|Disk|%s|avg wait (ms),aggregator=%s,value=%d\n", dev, agg, $10); 
   printf("name=Hardware Resources|Disk|%s|avg svctime (ms),aggregator=%s,value=%d\n", dev, agg, $11); 
   printf("name=Hardware Resources|Disk|%s|utilization (ms),aggregator=%s,value=%d\n", dev, agg, $12); 
   next
} 
( NF == 14 && state >= 2) { 
   state=2;
   agg="AVERAGE"; 
   dev = $1; 
   printf("name=Hardware Resources|Disk|%s|reads per sec,aggregator=%s,value=%d\n", dev, agg, $4); 
   printf("name=Hardware Resources|Disk|%s|writes per sec,aggregator=%s,value=%d\n", dev, agg, $5); 
   printf("name=Hardware Resources|Disk|%s|reads (kb/s),aggregator=%s,value=%d\n", dev, agg, $6); 
   printf("name=Hardware Resources|Disk|%s|writes (kb/s),aggregator=%s,value=%d\n", dev, agg, $7); 
   printf("name=Hardware Resources|Disk|%s|avg req size (s),aggregator=%s,value=%d\n", dev, agg, $8); 
   printf("name=Hardware Resources|Disk|%s|avg queue length,aggregator=%s,value=%d\n", dev, agg, $9); 
   printf("name=Hardware Resources|Disk|%s|avg wait (ms),aggregator=%s,value=%d\n", dev, agg, $10); 
   printf("name=Hardware Resources|Disk|%s|avg read await (ms),aggregator=%s,value=%d\n", dev, agg, $11); 
   printf("name=Hardware Resources|Disk|%s|avg write await (ms),aggregator=%s,value=%d\n", dev, agg, $12); 
   next
} '
