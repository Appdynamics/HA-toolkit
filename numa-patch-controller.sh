#!/bin/bash
#
# $Id: numa-patch-controller.sh 3.0 2016-08-04 03:09:03 cmayer $
#
# patch the controller.sh script to enable numa support
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
cd $(dirname $0)

CONTR_SH=../bin/controller.sh
CONTR_TMP=../bin/controller.sh.patch_tmp
CONTR_SAVE=../bin/controller.sh.pre-numa

err=0

# first, make a copy
cp $CONTR_SH $CONTR_TMP

#
# check if controller.sh has inclusion of NUMA settings
#
if ! grep -q "HA/numa.settings" $CONTR_TMP ; then
	ex -s $CONTR_TMP <<- ADDINCLUDE
/^INSTALL_DIR/
a

#### added by numa-patch-controller.sh ###
NUMA_MYSQL=
NUMA_JAVA=
if [ -f \$INSTALL_DIR/HA/numa.settings ] ; then
	. \$INSTALL_DIR/HA/numa.settings
fi
#### end addition ####

.
w
q
ADDINCLUDE
err=$?
fi

#
# check if controller.sh has mysqld_safe numa-ized
#
while grep "^[[:space:]]*bin/mysqld_safe" $CONTR_TMP;  do
	ex -s $CONTR_TMP <<- ADDMYSQL
	/^[[:space:]]*bin\/mysqld_safe
	i
	#### edited by numa-patch-controller.sh ####
	.
	+
	s,\(^[[:space:]]*\)\(bin/mysqld_safe\),\1\$NUMA_MYSQL \2,
	a
	#### end edit ####
	.
	w
	q
ADDMYSQL
	err=$?
done

#
# check if controller.sh has start-domain numa-ized
#
if grep "start-domain" $CONTR_TMP | grep -qv NUMA_JAVA ; then
	ex -s $CONTR_TMP <<- ADDSTARTDOMAIN
	/start-domain/
	i
	#### edited by numa-patch-controller.sh ####
	.
	+
	s,./asadmin start-domain,\$NUMA_JAVA ./asadmin start-domain,
	a
	#### end edit ####
	.
	w
	q
ADDSTARTDOMAIN
	err=$?
fi

if cmp -s $CONTR_SH $CONTR_TMP ; then
	echo controller.sh already patched
	rm $CONTR_TMP
else
	echo controller.sh patched for numa
	mv $CONTR_SH $CONTR_SAVE
	mv $CONTR_TMP $CONTR_SH
fi
