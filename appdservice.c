/*
 * $Id: appdservice.c 3.0 2016-08-04 12:22:17 cmayer $
 *
 *
 * Copyright 2016 AppDynamics, Inc
 *
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 *
 * this program is a trampoline for the Appdynamics user to invoke
 * a controlled escalation of privilege to cause changes in the
 * installed appdynamics services via the system's service wrapper,
 * which is root-only
 *
 * security is ensured by only changing the enumerated services
 * and the enumerated funtions.  
 *
 * this file contains all the distro specific knowledge
 * it is intentionally coded in a brute-force manner to be trivially auditable
 *
 * all the source strings for the execv array are internal to this file, and
 * all the input arguments are only read using strcmp;  buffer overflows
 * are not possible.
 *
 * also, since we use execv, no path processing is done.
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>

/*
 * these names are intentionally not the same pointer, even though they have
 * the same value.
 * we never copy anything from the arguments to the exec arguments.
 */
struct service {
	char *name;
	char *service_name;
} services[] = {
	{ "appdcontroller",		"appdcontroller" },
	{ "appdcontroller-db",	"appdcontroller-db" },
	{ "appdynamics-machine-agent", 	"appdynamics-machine-agent" }
};
#define NSRV (sizeof(services)/sizeof(services[0]))

/* number of possible handlers */
#define	NHAND	3

struct action {
	char *name;
	struct handler {
		char *prog;
		char *verb;
	} handlers[NHAND];
} actions[] = {
	{ "status", {
		{ "service", "status" },
		{ 0, 0 },
		{ 0, 0 }}
	},
	{ "start", {
		{ "service", "start" },
		{ 0, 0 },
		{ 0, 0 }}
	},
	{ "stop", {
		{ "service", "stop" },
		{ 0, 0 },
		{ 0, 0 }}
	},
	{ "enable", {
		{ "chkconfig", "on" },
		{ "update-rc.d", "enable" },
		{ 0, 0 }}
	},
	{ "disable", {
		{ "chkconfig", "off" },
		{ "update-rc.d", "disable" },
		{ 0, 0 }}
	}
};
#define NACT (sizeof(actions)/sizeof(actions[0]))

/*
 * the complete list of directories for lookup of commands
 */
char *bindirs[] = {
	"/sbin", "/usr/sbin", 0
};

void
usage(char *pname)
{
	int i, j;

	fprintf(stderr, "usage: %s <service> <action>\n", pname);
	for (i = 0; i < NSRV; i++) {
		fprintf(stderr, "\t%s {", services[i].name);
		for (j = 0; j < NACT; j++) {
			fprintf(stderr, "%s", actions[j].name);
			if (j < NACT - 1) {
				fprintf(stderr, ",");
			}
		}
		fprintf(stderr, "}\n");
	}
	exit (1);
}

/*
 * return zero if the program is executable in the specified directory
 */
int
executable_at(char *dir, char *prog)
{
	int dirfd;
	int ret;

	dirfd = open(dir, O_RDONLY | O_DIRECTORY);
	ret = faccessat(dirfd, prog, AT_EACCESS, X_OK);
	close(dirfd);
	return (ret);
}

char *argvec[4];
char *progpath;

int
main(int argc, char**argv)
{
	char cmdbuf[80];
	int svc;
	int act;
	int hand;
	char *prog;
	char *dir;
	
	if (argc != 3) {
		usage(argv[0]);
		exit (1);
	}

	/* look up service */
	for (svc = 0; svc < NSRV; svc++) {
		if (strcmp(services[svc].name, argv[1]) == 0) {
			break;
		}
	}
	if (svc >= NSRV) {
		fprintf(stderr, "unknown service %s\n", argv[1]);
		usage(argv[0]);
	}

	/* look up action */
	for (act = 0; act < NACT; act++) {
		if (strcmp(actions[act].name, argv[2]) == 0) {
			break;
		}
	}
	if (act >= NACT) {
		fprintf(stderr, "unknown action %s\n", argv[2]);
		usage(argv[0]);
	}

	/* validate that we are either the appdynamics user or root */
	if (getuid() != APPDUSER && getuid() != 0) {
		fprintf(stderr, "must be run as user id %d or root\n", APPDUSER);
		exit(2);
	}

	/* validate that we are effectively root */
	if (geteuid() != 0) {
		fprintf(stderr, "must be run setuid root\n");
		exit(3);
	}
	
	/* definitively become root */
	setreuid(0, 0);
	setregid(0, 0);

	/* iterate through handlers until null */
	for (hand = 0; prog = actions[act].handlers[hand].prog; hand++) {

		/* search the bindirs */
		for (dir = bindirs[0]; dir; dir++) {

			/* if we can run it, do so */
			if (executable_at(dir, prog)) {

				progpath = malloc(strlen(dir) + strlen(prog) + 2);
				strcpy(progpath, dir);
				strcat(progpath, "/");
				strcat(progpath, prog);
				argvec[0] = strdup(prog);
				argvec[1] = strdup(services[svc].service_name);
				argvec[2] = strdup(actions[act].handlers[hand].verb);
				argvec[3] = 0;

				execv(progpath, argvec);	
			}
		}
	}

	fprintf(stderr, "no valid handlers found for service %s action %s\n",
		services[svc].name, actions[act].name);
	exit(4);
}
