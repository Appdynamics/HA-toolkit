#!/bin/bash
#
# $Id: check_for_root_files.sh 3.1 2017-10-21 17:04:25 rob.navarro $
#
# Functions used to patch controller.sh by userid-patch-controller.sh
#
# starting Glassfish as root when it was previously installed and operated as a non-root
# user is a common reason for subsequent Glassfish startups to fail with almost no traceable
# logs. The later non-root startup fails to be able to write to now root-owned files.
# It is currently seen as unacceptable to prevent Glassfish startup as root when not 
# usually started as root and so we take the gentler approach of warning and providing 
# clean up instructions
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

# assume intended effective user name is that which was set during installation and
# saved away within the ${INSTALL_DIR}/db/db.cnf file under the "user" option
INSTALL_USER=$(awk -F= '$1 ~ /^[:space:]*user/ {print $2}' ${INSTALL_DIR}/db/db.cnf)
if [ -z "${INSTALL_USER}" ] ; then  
   INSTALL_USER=UNKNOWN_APPD_USER
fi

# group id of ${INSTALL_DIR}/appserver directory never seems to be wrongly set inadvertently, 
# assume it is now as it was at install time
INSTALL_GROUP=$(ls -dg ${INSTALL_DIR}/appserver | awk '{print $3}')
if [ -z "${INSTALL_GROUP}" ] ; then
   INSTALL_GROUP=UNKNOWN_APPD_GROUP
fi

userIdCleanupSteps ()
{
   echo "To repair an installation with inconsistent file permissions:
1. become root user
2. cd ${INSTALL_DIR}
3. stop all AppDynamics processes # e.g. bin/controller.sh stop
4. chown -R ${INSTALL_USER}:${INSTALL_GROUP} ${INSTALL_DIR:-<APPD_INSTALL_DIR>} ${MYSQL_DATADIR:-<MYSQL_DATADIR>}
5. exit root user and become user \"${INSTALL_USER}\"
6. start all AppDynamics processes as usual # e.g. bin/controller.sh start"
}

# Only a problem if Controller is started with a different effective user ID than when installed.
# Three different failing possibilities:
# 1. installed as root and now started as non-root - will fail
# 2. installed as non-root and now started as different non-root - will fail
# 3. installed as non-root and now started as root - will fail in future when started as non-root
warnIfDifferentEUID ()
{
   local CMD
   if [ `id -u -n` != "${INSTALL_USER}" ] ; then
      CMD="Your AppDynamics Controller was installed to use Linux user \"${INSTALL_USER}\" however you are now starting it with user \"$(id -u -n)\"."
      if [ "${INSTALL_USER}" = "root" ] || [ `id -u -n` != "root" ] ; then
         CMD="${CMD} The Controller will likely fail to start successfully."
      else
         CMD="${CMD} This will cause future Controller startups as user \"${INSTALL_USER}\" to fail. $(userIdCleanupSteps)"
      fi
      printf "\n${CMD}\n" >&2
      logger -p user.err -t "AppDynamics:$(basename $0):ERROR" <<< "$CMD"
   fi
}

# in case file permissions were wrongly set before a controller upgrade or by external action
# check some important directories for incorrect file ownership and report to user & syslog
warnIfBadFileOwnership ()
{
   # limit checked files to avoid false positives i.e. useless warnings
   local tosearch="logs/server.log logs/startAS.log appserver/glassfish/domains/domain1"
   local files=$(cd ${INSTALL_DIR}; find $tosearch -not -user ${INSTALL_USER})
   
   if [ -n "$files" ] ; then
      local not_writable=$(cd ${INSTALL_DIR}; find $tosearch -not -user ${INSTALL_USER} -not -writable)
      local certainty="may in future"

      # if any of those Glassfish files are not writable
      if [ `id -u -n` != "${INSTALL_USER}" ] && [ -n "$not_writable" ] ; then
         certainty=will
      fi

      local MSG="The following $(wc -l <<< "$files") file(s) are not owned by the Linux \"${INSTALL_USER}\" user and $certainty prevent successful Controller startup.
      $files

      $(userIdCleanupSteps)"
      printf "\n${MSG}\n" >&2
      logger -p user.warning -t "AppDynamics:$(basename $0):WARNING" <<< "$MSG"
   fi
}

# if current user unable to stop Glassfish then report that
checkIfWrongUser ()
{
   local gf_pid=$(pgrep -f "s/glassfish.jar ")
   [[ -z "$gf_pid" ]] && return			# skip test if no Glassfish running
   local gf_user=$(ps -o user= -p $gf_pid)

   # if can send signal 0 then allowed to send real signal
   if ! kill -s 0 -- $gf_pid &> /dev/null ; then
      local MSG="***** the running Controller application server must be shutdown as user \"${gf_user}\" *****";

      printf "\n${MSG}\n" >&2
      logger -p user.err -t "AppDynamics:$(basename $0):ERROR" <<< "$MSG"
      return 1
   fi
}

############
#_stopControllerAppServer ()
#{
## stop early if insufficient permissions to stop Glassfish
#checkIfWrongUser || exit 1
#
#
#_startControllerAppServer ()
#{
#warnIfBadFileOwnership
#warnIfDifferentEUID
#
############
