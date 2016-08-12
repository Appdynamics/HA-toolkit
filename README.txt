Contents:

	README: this file
	RUNBOOK:  a list of state descriptions, validations, and remedial actions


	replicate.sh:  the all-singing, all-dancing HA (re)activator
	this installs and sets up the HA function for a controller pair.

	appdcontroller.sh: a file intended to be placed into /etc/init.d to control
	the controller, watchdog, and assassin

	appdcontroller-db.sh: a file intended to be placed into /etc/init.d to control
	the mysql database

	appdynamics-machine-agent.sh: a file to start the machine agent

	assassin.sh:  a script run on a failed-over primary to kill the old primary

	failover.sh:  a script run on a secondary to become the new primary

	install-init.sh:  an installer for the appdcontroller.sh

	uninstall-init.sh:  an uninstaller for the appdcontroller.sh

	watchdog.sh:  run on a secondary to watch the primary and maybe failover

	watchdog.settings.template:  copy this to watchdog.settings to override defaults

	appdservice-root.sh:  a null privilege escalation wrapper

	appdservice-pbrun.sh:  a privilege escalation wrapper around pbrun

	appdservice.c:  a privilege escalation c program

	numa.settings.template: a template file containing numa static node assignments

	numa-patch-controller.sh:  a script to edit numa hooks into controller.sh

	appdcontroller-db.sysconfig: source files for system configuration
	appdcontroller.sysconfig
	appdynamics-machine-agent.sysconfig

	save_mysql_passwd.sh: a script used to obfuscate and save the mysql root password
	getaccess.sh:  a script to extract the access key from a database to set
			up monitoring

	appdstatus.sh: a script to replace 'service appdcontroller status' on 
		systemd machines

Installation notes:
This software is intended to connect the appdynamics controller into linux's
service machinery.  This optionally includes a watchdog process running on the
secondary HA node that will initiate a failover if a failure is detected in
the primary controller or database.

Permissions: 
	If the controller is to be run as a non-root user, part of the 
installation cannot be directly automated, as it involves installing of a 
system service into /etc/init.d and ancillary directories using install-init.sh

Prerequisites:
--------------
	1) Ssh must be installed in such a way that the user the controller is to 
be run as has symmetrical passwordless ssh access.  This is done by generating 
a key pair on each node, and placing the other's public key into the appropriate
authorized_keys file.  in detail, assuming user appduser, node1 and node2

	on node1:

	su - appduser
	mkdir -p .ssh
	ssh-keygen -t rsa -N "" -f .ssh/id_rsa
	scp .ssh/id_rsa.pub node2:/tmp

	on node2:

	su - appduser
	mkdir -p .ssh
	ssh-keygen -t rsa -N "" -f .ssh/id_rsa
	cat /tmp/id_rsa.pub >> .ssh/authorized_keys
	scp .ssh/id_rsa.pub node1:/tmp

	on node1:
	cat /tmp/id_rsa.pub >> ~/.ssh/authorized_keys

All of the above commands may not be needed, and some of them may prompt for a
password.

	2) reliable symmetrical reverse host lookup must be configured.  the best
way is to place the host names into each /etc/hosts file.   reverse DNS adds 
an additional point of failure.  
		a) /etc/nsswitch.conf should have files placed before dns. example:
			hosts:      files dns
		b) /etc/hosts:
			192.168.144.128 host1
			192.168.144.137 host2

	3) each machine must have the root and data directory writable by the 
appropriate appdynamics user:

	ls -lad /opt/AppDynamics/Controller
drwxr-xr-x. 18 appduser users    4096 Jan 26 18:18 /opt/AppDynamics/Controller

	4) the primary controller should be installed as a standalone controller;
the secondary should not be installed at all.

Installation:
-------------
On the primary, unpack the shar file using bash into a directory HA under the 
controller root install subdirectory.

	cd /opt/AppDynamics/Controller
	mkdir -p HA
	chmod +w *
	bash HA.shar
	
Mysql Password:
---------------
newer controllers remove the db/.rootpw file from the controller installation for
security reasons, plaintext passwords in data files being a known vulnerability.
as the HA package requires frequent database access, it is impractical to prompt
for the password every time the database is used.   accordingly, we decrypt the
password at each required access from a data file.  this data file must be written
by the save_mysql_passwd.sh script before running any component of the HA toolkit.

	cd HA
	./save_mysql_passwd.sh

	this will prompt for the mysql root password

Activation:
-----------
The key script to replicate the primary database to the secondary, make all the
appropriate state changes, and activate the HA pair is the replicate.sh script.
it is run on an active controller.  Attempts to run it on a passive controller 
will be rejected.  it has a few specialized options, but it has reasonable
defaults and is extracts a lot of configuration information from the existing
installation.  the most simple usage is to activate a HA pair immediately.
run the following as the same user as appdynamics is running as.
since the controller is taken down, the command will prompt for a confirmation message.

	./replicate.sh -s node2 -f -w -e proxy

when it has completed, the HA pair will be running and replicating.
If running as non-root, the command asks that some commands manually be run as
root to complete the installation.

Incremental Activation:
-----------------------
Runs of the replicate script without the -f option will perform an imperfect 
copy of the primary controller to the secondary without taking the primary down.
This can be used to minimize the downtime necessary to do the initial 
installation.  if the data volume to replicate is large, several runs without
the -f option would approach a perfect copy over a period of days.  the final
activation with -f during a maintenance window would only copy those data filesi
that differ from the last copy.

Privilege Escalation:
---------------------
the install-init.sh script is used to install the init scripts, and to set
up a controlled privilege escalation.  this can take the form of sudo settings,
or one of 3 flavors of /sbin/appdservice. run install-init.sh for usage.

Service Control:
----------------
After activation, the controller service and HA facility can be controlled 
using the linux service command.  these options must be executed as root.
The default installation will automatically shut down the controller when
the system is halted, and automatically start it at boot time.

	service appdcontroller start
	service appdcontroller stop

an additional service, appdcontroller-db, is used to manage the database.
a sensible dependency between the two services is implemented

Status:
-------
Once installed as a service, the linux service utility can be run on either
node to report the current state of the replication, background processes, and
the controller itself.

	service appdcontroller status

Watchdog:
---------
If enabled, this background process running on the secondary will monitor the
primary controller and database, and if it detects a failure, will initiate a
failover automatically.   The failure mode timings are defined in watchdog.sh.
The watchdog is only enabled if the file <controller root>/HA/WATCHDOG_ENABLE
exists. Removing the file causes the watchdog to exit.

to enable the watchdog, as root:
	touch <controller root>/HA/WATCHDOG_ENABLE
	chmod 777 <controller root>/HA/WATCHDOG_ENABLE
	service appdcontroller start

running the replicate.sh script with the -w option at final activation will 
create the watchdog control file automatically.

Assassin:
---------
After a failover, it is possible that the old primary may come online.  If this
occurs, the load balancer may send load to the old primary.  To prevent this,
the new primary continually polls the old primary and if it becomes accessible,
kills it and inhibits it from starting again.

Failover:
---------
A manual failover can be triggered by running failover.sh on the secondary.
This will kill the watchdog and activate the database.  it will also try to
assassinate the old primary.
This only happens if replication is broken. if replication is good, we just
deactivate the other appserver and activation this one, while leaving the db
up.  this case also does not fire up the assassin.

Logging:
--------
the logs directory contains several status and progress logs of the various components.

Remote controller monitoring
----------------------------
If desired it is possible to have the controller's internal Java app agent report to 
another controller. This is most often useful if two or more controllers have been
deployed on-premises. Having them both report their health to a controller monitor
simlifies the monitoring of them all as common health rules and notification policies are
more easily re-used.

At least four pieces of information are needed to configure remote controller 
monitoring:
	- controller monitor's hostname
	- controller monitor's port
	- account name within controller monitor
	- controller monitor's access key for that account
	- [optional] application name to report under

The controller monitor's account names and access keys can be determined with:
	cd <controller install dir>
	echo "select access_key,name,id from account\G"| bin/controller.sh login-db
	this has been put into a script:
	./getaccess.sh -p password -h monitorhost:3388
	this will output the access key.  you can specify account name.
	see usage.

You can send a controller's app agent output to another controller with hostname
"cmonitor", access_key "ac-ce-ss-key", account name "customer1", application name 
'Prod HA pair' with:
	./replicate.sh -s <secondary> -m url=http://cmonitor:8090,access_key="ac-ce-ss-key",account_name=customer1,app_name='Prod HA pair' -f

Machine Agent
-------------
Having a machine agent on both primary and secondary servers is a pre-requisite step 
to simple monitoring and warning of critical health issues affecting the stability
of the HA controller pair. Getting to this state involves:
	1. downloading and installing the machine agent on both primary and
	   secondary servers from download.appdynamics.com. For compatibility see 
	   docs.appdynamics.com for your version of the controller.
	   Ensure that the machine agent install directory is the *same* for both
	   primary and secondary servers.
	2. Ensure that the same version of the HA Toolkit is available on both
	   primary and secondary servers. Use scp or replicate.sh -s <other> 
	3. As root (re)run HA Toolkit install on both primary and secondary servers
	   including '-a <agent install dir>' parameter. For example:
		sudo ./install-init.sh -s -a /opt/appdyn/machine-agent/4.1.5.1
	   if the machine agent was extracted into the parent of the appdynamics
       controller, or the controller directory itself, the -a may be ommitted.
	4. As regular AppD user (re)run replicate.sh .. -f to shutdown controller and
	   configure all remaining files with an extra parameter referring to machine
	   agent install directory. For example:
	   	replicate.sh -s <secondary> -e https://proxy -a /opt/appdyn/machine-agent/3.9.0.0 -t 0 -z -f 

If a remote controller monitor has been configured, include that '-m' option in the 
replicate.sh command to ensure the machine agents report there also. For example:
		./replicate.sh -s <secondary> -m url=http://cmonitor:8090,access_key="ac-ce-ss-key",account_name=customer1,app_name='Prod HA pair' -a /opt/appdyn/machine-agent/3.9.0.0 -f
	 5. please note that the machine agent will be run as the same user as
        the mysql database.

NUMA
----
on a numa machine, it may be useful, for performance reasons,  to statically partition the machine to run mysqld on 
one set of nodes and the java appserver on another set of nodes.  this can be easily done by running numa-patch-controller.sh
from the HA directory, and copying the numa.settings.template to numa.settings.  edit numa.settings as needed.

Best Practices:
---------------
If possible, a dedicated network connection should be provisioned between the
HA pair.  this set of interfaces should be the ones placed into the /etc/hosts
files, and used as the argument for the -s option to the replicate.sh script.

Backups are best done by stopping the appdcontroller service on the secondary
and performing a file-level copy of the appdynamics directories.  these can
be incremental or complete, depending on the reliability of your solution.
when the backup is done, simply start the service; replication will catch up
and guarantee the integrity of your data.

A load balancer can probe http://<controller>:<port>/rest/serverstatus
to determine which of the two controllers is active. the active node will
return a HTTP 200.

should it be necessary to have a hook in the failover process, for example to update 
a dynamics DNS service or to notify a load balancer or proxy, the failover.sh script 
is the place to add code.

Version and Copyright
---------------------
$Id: README 1.13 2016-08-04 03:09:49 cmayer Exp $

 Copyright 2016 AppDynamics, Inc

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
