#+build linux
package lib

import "core:log"
import "core:sys/linux"

@(private)
_do_not_wait_for_children :: proc() {
	act := linux.Sig_Action(any) {
		flags = {.NOCLDWAIT},
	}
	if err := linux.rt_sigaction(.SIGCHLD, &act, (^linux.Sig_Action(any))(nil)); err != .NONE {
		log.panic("failed to sigaction", err)
	}
}
