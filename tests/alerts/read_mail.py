#!/usr/bin/env python3
"""Print one .eml from smtp_sink.py as JSON: from, to, subject, body (text part), attachment names."""
import email, email.policy, json, sys

m = email.message_from_binary_file(open(sys.argv[1], "rb"), policy=email.policy.default)
body = m.get_body(preferencelist=("plain",))
print(json.dumps({"from": str(m["From"]), "to": str(m["To"]), "subject": str(m["Subject"]),
                  "body": body.get_content() if body else "",
                  "attachments": sorted(p.get_filename() for p in m.iter_attachments())}))
