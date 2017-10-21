#!/bin/bash
#
# $Id: userid-patch-controller.sh 3.1 2017-10-21 17:04:25 rob.navarro $
#
# patch the controller.sh script to:
#   1. reduce failures around unexpected/root file ownership
#
# Copyright 2017 AppDynamics, Inc
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
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

cd $(dirname $0)

CONTR_SH=../bin/controller.sh
CONTR_TMP=../bin/controller.sh.userid-patch-tmp
CONTR_SAVE=../bin/controller.sh.pre-userid-patch

###########################################################
# Main body
###########################################################

# first, make a copy
cp $CONTR_SH $CONTR_TMP

#
# check if controller.sh already includes userID patches
#
if ! grep -q "added by userid-patch-controller.sh" $CONTR_TMP ; then
	ex -s $CONTR_TMP <<- 'ENDOFTEXT'
/^#######################/
a

#### added by userid-patch-controller.sh ####
embed check_for_root_files.sh
#### end addition ####

.
/^_stopControllerAppServer/
+
a
#### edited by userid-patch-controller.sh ####
# stop early if insufficient permissions to stop Glassfish
checkIfWrongUser || exit 1
#### end edit ####

.
/^_startControllerAppServer/
+
a
#### edited by userid-patch-controller.sh ####
warnIfBadFileOwnership
warnIfDifferentEUID
#### end edit ####

.
w
q
ENDOFTEXT
err=$?
fi


if cmp -s $CONTR_SH $CONTR_TMP ; then
	echo controller.sh already patched for userid issues
	rm $CONTR_TMP
else
	echo controller.sh patched for userid issues
	mv $CONTR_SH $CONTR_SAVE
	mv $CONTR_TMP $CONTR_SH
fi
