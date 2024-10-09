package main

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:sys/kqueue"
import "core:time"

MAX_CONCURRENT_CONNECTIONS :: 16384

register_new_client :: proc(queue: kqueue.KQ, socket_client: net.TCP_Socket) {
	change_list := [1]kqueue.KEvent {
		{ident = uintptr(socket_client), filter = .Read, flags = {.Add}},
	}
	n_events, err_kevent := kqueue.kevent(queue, change_list[:], nil, nil)
	if err_kevent != .NONE {
		log.panicf("failed to kevent(2) %v", err_kevent)
	}
	assert(n_events == 1)
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

	log_level_str := os.get_env("ODIN_LOG_LEVEL")
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
	case:
		log.panic("invalid log level in the environment variable ODIN_LOG_LEVEL", log_level_str)
	}


	endpoint_server := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = 12345,
	}


	// TODO: Make the socket non blocking?
	socket_server, err_listen := net.listen_tcp(endpoint_server, MAX_CONCURRENT_CONNECTIONS)
	if err_listen != nil {
		log.panicf("failed to listen %v", err_listen)
	}

	queue, err := kqueue.kqueue()
	if err != .NONE {
		log.panicf("failed to kqueue(2) %v", err)
	}

	{
		change_list := [1]kqueue.KEvent {
			{
				ident  = uintptr(socket_server),
				filter = .Read,
				flags  = {.Add},
				// Backlog.
				data   = MAX_CONCURRENT_CONNECTIONS,
			},
		}
		n_events, err_kevent := kqueue.kevent(queue, change_list[:], nil, nil)
		if err_kevent != .NONE {
			log.panicf("failed to kevent(2) %v", err_kevent)
		}
		assert(n_events == 0)
	}

	event_list := make([]kqueue.KEvent, MAX_CONCURRENT_CONNECTIONS)

	for {
		n_events, err_kevent := kqueue.kevent(queue, nil, event_list[:], nil)
		if err_kevent != .NONE {
			log.panicf("failed to kevent(2) %v", err_kevent)
		}
		log.debug("events", n_events)

		if n_events == 0 {
			time.sleep(10 * time.Millisecond)
		}

		for event in event_list[:n_events] {
			event_fd := net.TCP_Socket(event.ident)

			if .Error in event.flags { 	// Error.
				log.errorf("error %d", event.data)
				continue
			} else if .EOF in event.flags { 	// Disconnect
				log.debug("client disconnected")
				net.close(event_fd)
			} else if event_fd == socket_server { 	// New client.
				socket_client, endpoint_client, err_accept := net.accept_tcp(socket_server)
				if err_accept != nil {
					log.panicf("failed to accept(2) %v", err_accept)
				}

				register_new_client(queue, socket_client)
				log.debugf("new connection %v", endpoint_client)
			} else if kqueue.Filter.Read == event.filter {
				log.debugf("something to read")
				buf := [1024]u8{}
				n_recv, err_recv := net.recv_tcp(event_fd, buf[:])
				if err_recv != nil {
					log.errorf("failed to recv(2) %v", err_recv)
					net.close(event_fd)
					continue
				}
				log.debugf("read %d %v", n_recv, buf[:n_recv])
			} else {
				log.debugf("unknown event %v", event)
			}
		}
	}
}
