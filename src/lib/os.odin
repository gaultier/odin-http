package lib


do_not_wait_for_children :: proc() {
	_do_not_wait_for_children()
}

Pid :: distinct i32

fork :: proc() -> Pid {
	return _fork()
}
