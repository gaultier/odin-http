package main

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:sys/kqueue"

MAX_CONCURRENT_CONNECTIONS :: 16384

register_new_client :: proc(events: ^[dynamic]kqueue.KEvent) {
	event_read := kqueue.KEvent {
		.ident  = socket,
		.filter = .Read,
		.flags  = {.Add},
	}
	append(&events, event_read)
}

main :: proc() {
	context.logger = log.create_console_logger()

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


	endpoint_server := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = 12345,
	}


	socket_server, err_listen := net.listen_tcp(endpoint_server, MAX_CONCURRENT_CONNECTIONS)
	if err_listen != nil {
		log.panicf("failed to socket(2) %v", err_listen)
	}

	queue, err := kqueue.kqueue()
	if err != .NONE {
		log.panicf("failed to kqueue(2) %v", err)
	}

	// TODO: How many events per client?
	events := make([dynamic]kqueue.KEvent, 0, MAX_CONCURRENT_CONNECTIONS)
	for {
		socket_client, endpoint_client, err_accept := net.accept_tcp(socket_server)
		if err_accept != nil {
			log.panicf("failed to accept(2) %v", err_accept)
		}
		log.debugf("new connection %v", endpoint_client)

		register_new_client(&events)
	}
}
