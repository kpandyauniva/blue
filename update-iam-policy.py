#!/usr/bin/env python

import json
import sys

if len(sys.argv) != 2:
	print ("usage: update-iam-policy <new-service-account>")
	sys.exit(1)

policy = json.load(sys.stdin)
for b in policy["bindings"]:
	if b["role"] == "roles/editor":
		b["members"].append(u"serviceAccount:%s" % sys.argv[1])
print (json.dumps(policy))
sys.exit(0)
