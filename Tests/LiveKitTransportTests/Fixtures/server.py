#!/usr/bin/env python3
# Copyright 2026 LiveKit. Licensed under the Apache License, Version 2.0.
"""Local HTTP/WebSocket contract fixture; standard library only, no signaling logic."""
import base64
import gzip
import hashlib
import http.server
import ssl
import struct
import sys
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.startswith('/pending'):
            # Wait for the client to close, so cancellation also releases the fixture.
            self.connection.settimeout(40)
            try:
                self.connection.recv(1)
            except (TimeoutError, OSError):
                pass
            self.close_connection = True
            return
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
            self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
            self.end_headers()
            self.close_connection = True
            try:
                if self.path == '/close':
                    self.frame(8, struct.pack('!H', 1000))
                elif self.path == '/text':
                    self.frame(1, b'ignore')
                    self.frame(9, b'ping')
                while True:
                    head = self.rfile.read(2)
                    if len(head) != 2:
                        return
                    opcode, length = head[0] & 15, head[1] & 127
                    if length == 126:
                        length = struct.unpack('!H', self.rfile.read(2))[0]
                    elif length == 127:
                        length = struct.unpack('!Q', self.rfile.read(8))[0]
                    mask = self.rfile.read(4) if head[1] & 128 else b''
                    payload = self.rfile.read(length)
                    if mask:
                        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
                    if opcode == 8:
                        self.frame(8, payload)
                        return
                    if opcode == 10 and self.path == '/text':
                        self.frame(2, b'binary')
                    if opcode == 2:
                        self.frame(2, payload)
            except (OSError, ValueError):
                return
        else:
            body = b'error body' if self.path == '/error' else b'decoded body'
            self.send_response(429 if self.path == '/error' else 200)
            self.send_header('Retry-After', '7')
            if self.path == '/gzip':
                body = gzip.compress(body)
                self.send_header('Content-Encoding', 'gzip')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.send_response(201)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def frame(self, opcode, data):
        size = len(data)
        header = bytes([128 | opcode, size]) if size < 126 else bytes([128 | opcode, 126]) + struct.pack('!H', size)
        self.wfile.write(header + data)
        self.wfile.flush()


plain = http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler)
tls = http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[2])), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[3], sys.argv[4])
tls.socket = context.wrap_socket(tls.socket, server_side=True)
threading.Thread(target=tls.serve_forever, daemon=True).start()
print('ready', flush=True)
plain.serve_forever()
