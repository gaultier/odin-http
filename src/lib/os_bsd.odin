#+build darwin, netbsd, openbsd, freebsd
package lib

import "core:log"
import "core:sys/posix"


@(private)
_do_not_wait_for_children :: proc() {
	act := posix.sigaction_t {
		sa_flags = {.NOCLDWAIT},
	}
	if posix.sigaction(.SIGCHLD, &act, nil) != .OK {
		log.panic("failed to sigaction", posix.errno())
	}
}

@(private)
_fork :: proc() -> Pid {
	pid := posix.fork()
	if pid == -1 {
		panic("failed to fork(2)")
	}
	return Pid(pid)
}
