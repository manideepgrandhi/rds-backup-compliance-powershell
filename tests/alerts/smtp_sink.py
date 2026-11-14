#!/usr/bin/env python3
"""Tiny SMTP sink for the alert tests: accepts every message, writes each one to OUT_DIR/mail_N.eml.

usage: smtp_sink.py OUT_DIR   -> prints the port it listens on (127.0.0.1), then serves until killed.
Plain SMTP only (no TLS, no AUTH); enough for System.Net.Mail.SmtpClient.
"""
import os, socket, sys, threading

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", 0)); srv.listen(5)
print(srv.getsockname()[1], flush=True)
count = [0]; lock = threading.Lock()


def handle(c):
    f = c.makefile("rb"); w = lambda s: c.sendall((s + "\r\n").encode())
    w("220 sink ESMTP")
    env = {"from": "", "to": []}
    while True:
        line = f.readline()
        if not line: break
        cmd = line.decode("utf-8", "replace").strip(); up = cmd.upper()
        if up.startswith("EHLO") or up.startswith("HELO"): w("250 sink")
        elif up.startswith("MAIL FROM"): env["from"] = cmd[10:].strip(); w("250 ok")
        elif up.startswith("RCPT TO"): env["to"].append(cmd[8:].strip()); w("250 ok")
        elif up == "DATA":
            w("354 go"); data = []
            while True:
                l = f.readline()
                if not l or l in (b".\r\n", b".\n"): break
                data.append(l[1:] if l.startswith(b"..") else l)
            with lock:
                count[0] += 1; n = count[0]
            with open(os.path.join(out, "mail_%d.eml" % n), "wb") as fh:
                fh.write(("X-Sink-From: %s\r\nX-Sink-To: %s\r\n" % (env["from"], ",".join(env["to"]))).encode())
                fh.write(b"".join(data))
            w("250 queued"); env = {"from": "", "to": []}
        elif up == "QUIT": w("221 bye"); break
        else: w("250 ok")
    c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
