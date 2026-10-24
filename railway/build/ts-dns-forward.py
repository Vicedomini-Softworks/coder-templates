#!/usr/bin/python3 -I
"""Split DNS forwarder for tailscaled in userspace-networking mode.

Without /dev/net/tun, tailscaled cannot apply the tailnet's DNS settings:
its SOCKS5/HTTP proxy resolves names with /etc/resolv.conf like any other
process, so names only the tailnet's DNS server knows (e.g. *.corp behind
a subnet router) fail with "no such host".

This forwarder listens on LISTEN (UDP and TCP, port 53) and is put first in
/etc/resolv.conf by the Coder "tailscale" script. Queries under one of
DOMAINS are sent as DNS-over-TCP through the tailscaled SOCKS5 proxy to the
tailnet DNS server; everything else goes unchanged to the original
nameservers. Stdlib only, no state, safe to restart.

Usage: ts-dns-forward --domains corp.example,... --tailnet-dns 10.0.0.10
                      --fallback fd12::10[,...] [--listen 127.0.0.53]
                      [--socks 127.0.0.1:1055]
"""

import argparse
import ipaddress
import socket
import socketserver
import struct
import sys
import threading

TIMEOUT = 5


def qname(msg):
    """Lower-case query name of a DNS message, '' if unparsable."""
    labels, i = [], 12
    try:
        while msg[i]:
            n = msg[i]
            if n & 0xC0:
                return ""
            labels.append(msg[i + 1 : i + 1 + n].decode("ascii", "replace"))
            i += 1 + n
    except IndexError:
        return ""
    return ".".join(labels).lower()


def servfail(msg):
    if len(msg) < 12:
        return b""
    flags = struct.unpack(">H", msg[2:4])[0]
    return msg[:2] + struct.pack(">H", (flags | 0x8000) & 0xFFF0 | 2) + msg[4:6] + b"\0" * 6 + msg[12:]


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("short read")
        buf += chunk
    return buf


def tcp_exchange(sock, msg):
    sock.sendall(struct.pack(">H", len(msg)) + msg)
    return recv_exact(sock, struct.unpack(">H", recv_exact(sock, 2))[0])


def socks_connect(proxy, host, port):
    s = socket.create_connection(proxy, timeout=TIMEOUT)
    try:
        s.sendall(b"\x05\x01\x00")
        if recv_exact(s, 2) != b"\x05\x00":
            raise ConnectionError("SOCKS5 auth rejected")
        ip = ipaddress.ip_address(host)
        atyp = b"\x01" if ip.version == 4 else b"\x04"
        s.sendall(b"\x05\x01\x00" + atyp + ip.packed + struct.pack(">H", port))
        rep = recv_exact(s, 4)
        if rep[1] != 0:
            raise ConnectionError("SOCKS5 connect failed: %d" % rep[1])
        recv_exact(s, {1: 4, 4: 16}.get(rep[3], 0) + 2)
        return s
    except Exception:
        s.close()
        raise


class Forwarder:
    def __init__(self, args):
        self.domains = [d.strip(".").lower() for d in args.domains.split(",") if d.strip(".")]
        self.tailnet_dns = args.tailnet_dns
        self.fallback = [f for f in args.fallback.split(",") if f]
        host, _, port = args.socks.rpartition(":")
        self.socks = (host, int(port))

    def is_tailnet(self, name):
        return any(name == d or name.endswith("." + d) for d in self.domains)

    def resolve(self, msg, client_tcp=False):
        try:
            if self.is_tailnet(qname(msg)):
                with socks_connect(self.socks, self.tailnet_dns, 53) as s:
                    return tcp_exchange(s, msg)
            last = None
            for server in self.fallback:
                try:
                    if client_tcp:
                        with socket.create_connection((server, 53), timeout=TIMEOUT) as s:
                            return tcp_exchange(s, msg)
                    family = socket.AF_INET6 if ":" in server else socket.AF_INET
                    with socket.socket(family, socket.SOCK_DGRAM) as s:
                        s.settimeout(TIMEOUT)
                        s.sendto(msg, (server, 53))
                        return s.recv(65535)
                except OSError as e:
                    last = e
            raise last or OSError("no fallback nameserver")
        except Exception as e:  # never crash the server on one bad query
            print("query %r failed: %s" % (qname(msg), e), file=sys.stderr, flush=True)
            return servfail(msg)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--domains", required=True)
    p.add_argument("--tailnet-dns", required=True)
    p.add_argument("--fallback", required=True)
    p.add_argument("--listen", default="127.0.0.53")
    p.add_argument("--socks", default="127.0.0.1:1055")
    args = p.parse_args()
    fwd = Forwarder(args)

    class UDP(socketserver.BaseRequestHandler):
        def handle(self):
            data, sock = self.request
            reply = fwd.resolve(data)
            if reply:
                sock.sendto(reply, self.client_address)

    class TCP(socketserver.BaseRequestHandler):
        def handle(self):
            self.request.settimeout(TIMEOUT)
            try:
                while True:
                    msg = recv_exact(self.request, struct.unpack(">H", recv_exact(self.request, 2))[0])
                    reply = fwd.resolve(msg, client_tcp=True)
                    self.request.sendall(struct.pack(">H", len(reply)) + reply)
            except (OSError, ConnectionError):
                pass

    socketserver.ThreadingUDPServer.daemon_threads = True
    socketserver.ThreadingTCPServer.daemon_threads = True
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    udp = socketserver.ThreadingUDPServer((args.listen, 53), UDP)
    tcp = socketserver.ThreadingTCPServer((args.listen, 53), TCP)
    threading.Thread(target=tcp.serve_forever, daemon=True).start()
    print("forwarding %s -> %s via SOCKS5 %s:%d, rest -> %s"
          % (",".join(fwd.domains), fwd.tailnet_dns, *fwd.socks, ",".join(fwd.fallback)), flush=True)
    udp.serve_forever()


if __name__ == "__main__":
    main()
