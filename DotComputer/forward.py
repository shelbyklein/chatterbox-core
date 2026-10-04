#!/usr/bin/env python3
"""Inside the agent computer: makes http://localhost:PORT reach the same port on the Mac,
for a local preview the user enabled in Chatterbox. Listens on this computer's loopback
only; Chatterbox's relay on the Mac answers only for enabled ports."""
import socket, sys, threading

port = int(sys.argv[1])
mac = socket.gethostbyname("host.docker.internal")   # IPv4: the Mac's loopback, via Docker

def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.listen(32)
while True:
    client, _ = server.accept()
    try:
        upstream = socket.create_connection((mac, port), timeout=10)
        upstream.settimeout(None)
    except OSError:
        client.close()
        continue
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()
