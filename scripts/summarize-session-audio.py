#!/usr/bin/env python3
"""Summarize first decoded native audio, excluding explicit warmup samples."""
import argparse
import csv
import json
import math
from pathlib import Path
import re
import statistics
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('log', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--added-signaling-rtt-ms', type=int, default=100)
args = parser.parse_args()
text = args.log.read_text()
if 'Test run with 1 test in 1 suite passed' not in text:
    raise SystemExit('The native audio benchmark did not pass.')
pattern = re.compile(r'SESSION_AUDIO_BENCH (spc|dual),(0|800),(-?\d+),(baseline|prepared),([\d.]+),([\d.]+),([\d.]+)')
rows = []
for match in pattern.finditer(text):
    pc, delay, sample, mode, connected, uplink, downlink = match.groups()
    if int(sample) < 0:
        continue
    rows.append(dict(pc=pc, capture_delay_ms=int(delay), sample=int(sample), mode=mode,
                     connected_ms=float(connected), first_outgoing_pcm_ms=float(uplink),
                     first_incoming_pcm_ms=float(downlink)))
if not rows:
    raise SystemExit('No measured samples found.')
summary = []
for pc in ['spc', 'dual']:
    for delay in [0, 800]:
        for mode in ['baseline', 'prepared']:
            group = [row for row in rows if (row['pc'], row['capture_delay_ms'], row['mode']) == (pc, delay, mode)]
            if not group:
                raise SystemExit(f'Missing samples: {pc}/{delay}/{mode}')
            item = dict(pc=pc, capture_delay_ms=delay, mode=mode, samples=len(group))
            for metric in ['connected_ms', 'first_outgoing_pcm_ms', 'first_incoming_pcm_ms']:
                values = sorted(row[metric] for row in group)
                item[metric] = dict(median=round(statistics.median(values), 2),
                                    p95=round(values[math.ceil(len(values) * .95) - 1], 2))
            summary.append(item)
counts = {item['samples'] for item in summary}
if len(counts) != 1:
    raise SystemExit('Unbalanced sample counts.')
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
report = dict(source_revision=revision, added_signaling_rtt_ms=args.added_signaling_rtt_ms,
              token_delay_ms=100, media_network='direct loopback UDP, no added media delay',
              source='generated 400 Hz PCM, native manual rendering mode, actual Opus/SFU/decoder',
              baseline='previous Session capture -> credentials -> Room.connect -> publish sequence',
              companion='warm participant publishing audio before Session starts; no agent dispatch or AI inference',
              samples=rows, summary=summary)
args.output.mkdir(parents=True, exist_ok=True)
(args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
with (args.output / 'samples.csv').open('w') as output:
    writer = csv.DictWriter(output, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
for item in summary:
    print(f"{item['pc']:4} capture={item['capture_delay_ms']:3}ms {item['mode']:8} n={item['samples']} "
          f"connected={item['connected_ms']['median']:7.1f}ms "
          f"outgoing={item['first_outgoing_pcm_ms']['median']:7.1f}ms "
          f"incoming={item['first_incoming_pcm_ms']['median']:7.1f}ms")
