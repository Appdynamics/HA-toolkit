#include "fcntl.h"

main(int argc, char **argv)
{
	char **p;
	int i;
	int o;

	o=open("scplog", O_RDWR|O_APPEND|O_CREAT, 0777);
	for (i = 0; i < argc; i++) {
		write(o, "\'", 1);
		write(o, argv[i], strlen(argv[i]));
		write(o, "\'", 1);
		write(o, " ", 1);
	}
	write(o, "\n", 1);
	execvp("scp", argv);
}
