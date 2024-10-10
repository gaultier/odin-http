package main
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strings"

import "lib"

MAX_CONCURRENT_CONNECTIONS :: 16384

handle_client :: proc(socket_client: net.TCP_Socket) {
	pid, err := os.fork()
	if err != nil {
		log.panic("failed to fork(2)", err)
	}

	if pid > 0 { 	// Parent.
		return
	}
}

main :: proc() {
	arena: virtual.Arena
	{
		arena_size := uint(1) * mem.Megabyte
		mmaped, err := virtual.reserve_and_commit(arena_size)
		if err != nil {
			log.panicf("failed to mmap %v", err)
		}
		if err = virtual.arena_init_buffer(&arena, mmaped); err != nil {
			log.panicf("failed to create main arena %v", err)
		}
	}
	context.allocator = virtual.arena_allocator(&arena)


	tmp_arena: virtual.Arena
	{
		tmp_arena_size := uint(1) * mem.Megabyte
		tmp_mmaped, err := virtual.reserve_and_commit(tmp_arena_size)
		if err != nil {
			log.panicf("failed to create mmap %v", err)
		}
		if err = virtual.arena_init_buffer(&tmp_arena, tmp_mmaped); err != nil {
			log.panicf("failed to create temp arena %v", err)
		}
	}
	context.temp_allocator = virtual.arena_allocator(&tmp_arena)

	context.logger = log.create_console_logger(.Error)
	log_level_str := strings.trim_space(os.get_env("ODIN_LOG_LEVEL"))
	switch log_level_str {
	case "debug":
		context.logger = log.create_console_logger(.Debug)
	case "info":
		context.logger = log.create_console_logger(.Info)
	case "error":
		context.logger = log.create_console_logger(.Error)
	case "warning":
		context.logger = log.create_console_logger(.Warning)
	case "fatal":
		context.logger = log.create_console_logger(.Fatal)
	case "":
		context.logger = log.create_console_logger(.Error)
	case:
		log.panicf(
			"invalid log level in the environment variable ODIN_LOG_LEVEL `%s`",
			log_level_str,
		)
	}

	lib.do_not_wait_for_children()

	endpoint_server := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = 12345,
	}


	// TODO: Make the socket non blocking?
	socket_server, err_listen := net.listen_tcp(endpoint_server, MAX_CONCURRENT_CONNECTIONS)
	if err_listen != nil {
		log.panic("failed to listen", err_listen)
	}

	if err := net.set_option(socket_server, .Reuse_Address, true); err != nil {
		log.panic("failed to setsockopt(2)", err)
	}

	when ODIN_OS == .FreeBSD {
		if err := net.set_option(socket_server, .Reuse_Port, true); err != nil {
			log.panic("failed to setsockopt(2)", err)
		}
	}

	for {
		socket_client, endpoint_client, err_accept := net.accept_tcp(socket_server)
		if err_accept != nil {
			log.panic("failed to accept(2)", err_accept)
		}
		log.debug("new client", endpoint_client)

		handle_client(socket_client)
	}
}
