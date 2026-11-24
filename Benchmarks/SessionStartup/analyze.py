"""Summarize the opt-in Session sequencing benchmark; no dependencies."""
import json
import math
import random
import statistics
from pathlib import Path

rows = json.loads(Path(__file__).with_name("samples.json").read_text())
rng = random.Random(1227)
metrics = ("connectedMs", "publishedMs", "firstAudioMs")
print("# Concurrent Session startup results\n")
print("All values are milliseconds from startup. Median baseline → concurrent; "
      "negative deltas mean faster. Ten runs per arm/condition, with one excluded warmup pair.\n")
print("| Capture delay | Preconnect buffer | Connected | Published/start returned | First decoded audio |")
print("| --- | --- | ---: | ---: | ---: |")
intervals = []
for delay in (0, 1000):
    for buffer in (False, True):
        groups = [[r for r in rows if r["captureDelayMs"] == delay and r["preConnectAudio"] == buffer
                   and r["concurrent"] == candidate] for candidate in (False, True)]
        assert len(groups[0]) == len(groups[1]) == 10
        cells = []
        cis = []
        for metric in metrics:
            old, new = [[r[metric] for r in group] for group in groups]
            a, b = statistics.median(old), statistics.median(new)
            cells.append(f"{a:.0f} → {b:.0f}")
            draws = sorted(statistics.median(rng.choices(new, k=len(new))) -
                           statistics.median(rng.choices(old, k=len(old))) for _ in range(20000))
            low, high = [draws[math.ceil(q * len(draws)) - 1] for q in (.025, .975)]
            cis.append(f"{round(b-a):+d} [{round(low):+d}, {round(high):+d}]")
        label = "on" if buffer else "off"
        print(f"| {delay} ms | {label} | " + " | ".join(cells) + " |")
        intervals.append(f"| {delay} ms | {label} | " + " | ".join(cis) + " |")
print("\nExploratory candidate-minus-baseline median deltas and percentile 95% bootstrap "
      "intervals (20,000 independent resamples per comparison, seed 1227):\n")
print("| Capture delay | Preconnect buffer | Connected | Published/start returned | First decoded audio |")
print("| --- | --- | ---: | ---: | ---: |")
print("\n".join(intervals))
print("\nSmall controlled samples, unadjusted for multiple comparisons; not production tail or "
      "significance estimates. Immediate means zero injected capture delay, not zero device/SDK work.")
