/* A real raise() for the M2 build: deliver the signal to our own process
 * so abort() actually raises SIGABRT rather than falling into its
 * null-deref "fail in any way possible" path. Uses the raw syscall
 * primitives (already linked just above via syscall.c); avoids pid_t so it
 * works with the minimal type set the M2 build sees at this point. */

int
__raise (int signum)
{
  return _sys_call2 (SYS_kill, _sys_call (SYS_getpid), signum);
}
