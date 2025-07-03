const std = @import("std");
const net = std.net;

/// [ ] maintain a list of subscribers with of host -> port (in memory for now)
/// [ ] check if the host header matches any subscriber
/// [ ] foreword request to that subscriber
/// [ ] stream response from subscriber to client
/// [ ] support multiplexing using async io
pub fn main() !void {
    const address = try net.Address.resolveIp("127.0.0.1", 4221);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    std.debug.print("Listening on {}\n", .{listener.listen_address});

    defer listener.deinit();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var subscribers = std.StringHashMap(u16).init(arena.allocator());
    try subscribers.put("mybackend.com", 4000);

    while (true) {
        var request_arena = std.heap.ArenaAllocator.init(arena.allocator());
        defer _ = request_arena.reset(.retain_capacity);
        const allocator = request_arena.allocator();

        const client_connection = try listener.accept();
        std.debug.print("-------Connection received from {}-------\n", .{client_connection.address});
        // TODO: handle errors properly
        const request = readRequest(client_connection.stream.reader(), allocator) catch |err| switch (err) {
            ParseError.InvalidRequest => {
                _ = try client_connection.stream.write("HTTP/1.1 400 Bad Request\r\n");
                continue;
            },
            else => {
                return err;
            },
        };
        std.debug.print("memory allocated for this request: {}\n", .{arena.queryCapacity()});

        if (request.headers.get("host")) |host| {
            if (subscribers.get(host)) |port| {
                std.debug.print("found subscriber with host {s} on port {}", .{ host, port });
            }
        }

        std.debug.print("parsed request:\n{s} {s} {s}\n", .{
            request.method,
            request.path,
            request.version,
        });

        var headers_it = request.headers.iterator();
        while (headers_it.next()) |header| {
            std.debug.print("Header: {s}: {s}\n", .{ header.key_ptr.*, header.value_ptr.* });
        }
        std.debug.print("body_prebuffer:\n{s}\n", .{request.body_prebuffer});

        std.debug.print("Writing data to {}.\n", .{client_connection.address});
        if (std.mem.eql(u8, request.path, "/")) {
            _ = try client_connection.stream.write("HTTP/1.1 200 OK\r\n");
        } else {
            _ = try client_connection.stream.write("HTTP/1.1 404 Not Found\r\n");
        }
    }
}

const Request = struct {
    method: []const u8,
    path: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    body_prebuffer: []const u8 = "",
    // body: std.net.Stream.Reader,
};

const ParseError = error{
    InvalidRequest,
    HeaderParseError,
};

fn readRequest(
    reader: std.net.Stream.Reader,
    allocator: std.mem.Allocator,
) !Request {
    var buffer = try allocator.alloc(u8, 4 * 1024);
    const bytes_read = try reader.read(buffer);

    const headers_end = blk: {
        var window_end: usize = 4;
        var headers_end: usize = 0;
        for (0..bytes_read) |i| {
            if (std.mem.eql(u8, buffer[i..window_end], "\r\n\r\n")) {
                headers_end = window_end;
            }
            window_end += 1;
        }

        break :blk headers_end;
    };

    const headers_buffer = buffer[0..headers_end];
    const body_prebuffer = buffer[headers_end..bytes_read];

    var lines = std.mem.splitSequence(u8, headers_buffer, "\r\n");

    var request: Request = blk: {
        const request_line = lines.next() orelse return ParseError.InvalidRequest;
        var tokens = std.mem.splitScalar(u8, request_line, ' ');

        break :blk .{
            .method = tokens.next() orelse return ParseError.InvalidRequest,
            .path = tokens.next() orelse return ParseError.InvalidRequest,
            .version = tokens.next() orelse return ParseError.InvalidRequest,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body_prebuffer = body_prebuffer,
        };
    };

    while (lines.next()) |line| {
        if (line.len == 0) continue; // Skip empty lines

        var key_value = std.mem.splitScalar(u8, line, ':');
        const key = key_value.next() orelse return ParseError.InvalidRequest;
        const value = key_value.next() orelse return ParseError.InvalidRequest;
        request.headers.put(key, std.mem.trimLeft(u8, value, " ")) catch return ParseError.HeaderParseError;
    }

    // request.body = reader;

    return request;
}
