#!/bin/sh
#
# Monitors Processes on Linux
#
# version 1.0
#
#########################################

PATH=$PATH:/bin:/usr/sbin:/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
# fire every 6 seconds
INTERVAL=6

declare -a procs

while [ 1 ]; do
  procs[0]="machineagent,$(pgrep -f '/machineagent.jar' | tail -1)"
  procs[1]="glassfish,$(pgrep -f '/glassfish.jar ' | tail -1)"
  procs[2]="mysqld,$(pgrep -f '/mysqld ' | tail -1)" 

  for ii in "${procs[@]}"; do
    ii=(${ii//,/ });
    name=${ii[0]};
    pid=${ii[1]};
    grep 'Vm\|Threads' /proc/${pid}/status | sed -e 's#kB$#_kB#' -e 's#^\([^:]*\):[ \t]*\([^ \t]*\)[ \t]*\([^ \t]*\)$#name=Hardware Resources|Proc Status|'"${name}"'|\1\3,aggregator=AVERAGE,value=\2#';
  done;

  timeParts=($(date "+%s %3N"));
  sleepTime="$(( (${INTERVAL} - 1) - (${timeParts[0]} % ${INTERVAL}) )).$(printf "%03d" $(( 2000 - 1${timeParts[1]})))";
  sleep "${sleepTime}"
done

