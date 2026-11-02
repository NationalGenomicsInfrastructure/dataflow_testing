#!/usr/bin/env python3
"""
Add transferred_to_hpc event to a flowcell_status document if it doesn't already exist.
"""

import json
import sys

# Read the input JSON
doc = json.load(sys.stdin)

# Get timestamp from command line argument
if len(sys.argv) > 1:
    timestamp = sys.argv[1]
else:
    from datetime import datetime, timezone
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

# Check if transferred_to_hpc event already exists
has_event = False
for event in doc.get('events', []):
    if event.get('event_type') == 'transferred_to_hpc':
        has_event = True
        break

# Add the event if it doesn't exist
if not has_event:
    doc['events'].append({
        'event_type': 'transferred_to_hpc',
        'timestamp': timestamp,
        'data': {}
    })

# Output the modified JSON
json.dump(doc, sys.stdout, separators=(',', ':'))