package main
import "core:bytes"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "lib"

MAX_CONCURRENT_CONNECTIONS :: 16384
MAX_REQUEST_LENGTH :: 128 * mem.Kilobyte
MAX_REQUEST_LINES :: 256
NEWLINE: string : "\r\n"

is_numerical :: proc(s: []u8) -> bool {
	for c in s {
		switch c {
		case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9':
			continue
		case:
			return false
		}
	}

	return true
}

request_find_content_length :: proc(req: []u8) -> (content_length: u64, ok: bool) {
	header_key: string : "Content-Length: "
	header_key_idx := bytes.index(req, transmute([]u8)header_key)
	if header_key_idx == -1 {return 0, false}

	newline_idx := bytes.index(req[header_key_idx:], transmute([]u8)NEWLINE)
	if newline_idx == -1 {return 0, false}

	header_value := bytes.trim_space(req[header_key_idx:header_key_idx + newline_idx])

	if !is_numerical(header_value) {return 0, false}

	return strconv.parse_u64(transmute(string)header_value)
}

Request :: struct {}

Read_Proc :: #type proc(socket: net.TCP_Socket, buf: []u8) -> (n: int, err: net.Network_Error)

Reader :: struct {
	socket:    net.TCP_Socket,
	read_more: Read_Proc,
	buf:       [dynamic]u8,
	idx:       int,
}

reader_consume_line :: proc(reader: ^Reader) -> (line: []u8, ok: bool) {
	if reader.idx >= len(reader.buf) {
		return
	}

	newline_index := bytes.index(reader.buf[reader.idx:], transmute([]u8)NEWLINE)

	if newline_index == -1 {
		return
	}

	res := reader.buf[reader.idx:][:newline_index]
	reader.idx += newline_index + len(NEWLINE)
	return res, true
}

reader_read_line :: proc(reader: ^Reader) -> (line: []u8, err: net.Network_Error) {
	for _ in 0 ..< 10 {
		ok: bool
		line, ok = reader_consume_line(reader)
		if ok {
			return line, nil
		}

		buf: [4096]u8
		n_read := reader.read_more(reader.socket, buf[:]) or_return

		append(&reader.buf, ..buf[:n_read])
	}
	return
}

read_full_request :: proc(reader: ^Reader) -> (request: Request, err: net.Network_Error) {
	status_line := reader_read_line(reader) or_return
	log.debug("status_line", status_line)

	line := status_line
	for _ in 0 ..< MAX_REQUEST_LINES {
		line = reader_read_line(reader) or_return
		log.debug("line", line)

		if len(line) == 0 { 	// Reached the end of the lines
			break
		}
	}

	return
}

handle_client :: proc(socket_client: net.TCP_Socket) -> (err: net.Network_Error) {
	reader := Reader {
		socket    = socket_client,
		read_more = net.recv_tcp,
	}
	read_full_request(&reader) or_return

	return
}

spawn_client_process :: proc(socket_client: net.TCP_Socket) {
	pid, err := os.fork()
	if err != nil {
		log.panic("failed to fork(2)", err)
	}

	if pid > 0 { 	// Parent.
		net.close(socket_client)
		return
	}

	handle_client(socket_client)
	os.exit(0)
}

make_logger_from_env :: proc(env_level: string) -> log.Logger {
	logger := log.create_console_logger(.Error)
	log_level_str := strings.trim_space(env_level)

	switch log_level_str {
	case "debug":
		logger = log.create_console_logger(.Debug)
	case "info":
		logger = log.create_console_logger(.Info)
	case "error":
		logger = log.create_console_logger(.Error)
	case "warning":
		logger = log.create_console_logger(.Warning)
	case "fatal":
		logger = log.create_console_logger(.Fatal)
	case "":
		logger = log.create_console_logger(.Error)
	case:
		log.panicf(
			"invalid log level in the environment variable ODIN_LOG_LEVEL `%s`",
			log_level_str,
		)
	}
	return logger
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

	context.logger = make_logger_from_env(os.get_env("ODIN_LOG_LEVEL"))

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

		spawn_client_process(socket_client)
	}
}

@(test)
test_reader_read_line :: proc(_: ^testing.T) {
	read_more :: proc(socket: net.TCP_Socket, buf: []u8) -> (n: int, err: net.Network_Error) {
		data := "GET / HTTP/1.1\r\nHost: 0.0.0.0:12345\r\nUser-Agent: curl/8.6.0\r\nAccept: */*\r\n\r\n"
		mem.copy(raw_data(buf[:len(data)]), raw_data(transmute([]u8)data), len(data))
		return len(data), nil
	}
	reader := Reader {
		read_more = read_more,
	}

	{
		status_line, err := reader_read_line(&reader)
		assert(err == nil)
		assert(transmute(string)status_line == "GET / HTTP/1.1")
	}
	{
		line, err := reader_read_line(&reader)
		assert(err == nil)
		assert(transmute(string)line == "Host: 0.0.0.0:12345")
	}
	{
		line, err := reader_read_line(&reader)
		assert(err == nil)
		assert(transmute(string)line == "User-Agent: curl/8.6.0")
	}
	{
		line, err := reader_read_line(&reader)
		assert(err == nil)
		assert(transmute(string)line == "Accept: */*")
	}
}

@(test)
test_reader_full_request :: proc(_: ^testing.T) {
	read_more :: proc(socket: net.TCP_Socket, buf: []u8) -> (n: int, err: net.Network_Error) {
		data := "GET / HTTP/1.1\r\nHost: 0.0.0.0:12345\r\nUser-Agent: curl/8.6.0\r\nAccept: */*\r\n\r\n"
		mem.copy(raw_data(buf[:len(data)]), raw_data(transmute([]u8)data), len(data))
		return len(data), nil
	}
	reader := Reader {
		read_more = read_more,
	}

	req, err := read_full_request(&reader)
	assert(err == nil)
	_ = req
}
