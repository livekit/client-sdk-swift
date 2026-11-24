# Concurrent Session startup results

All values are milliseconds from startup. Median baseline → concurrent; negative deltas mean faster. Ten runs per arm/condition, with one excluded warmup pair.

| Capture delay | Preconnect buffer | Connected | Published/start returned | First decoded audio |
| --- | --- | ---: | ---: | ---: |
| 0 ms | off | 375 → 375 | 390 → 383 | 444 → 444 |
| 0 ms | on | 379 → 380 | 385 → 390 | 453 → 453 |
| 1000 ms | off | 373 → 382 | 1392 → 1020 | 1457 → 1081 |
| 1000 ms | on | 1385 → 379 | 1398 → 1019 | 1458 → 1078 |

Exploratory candidate-minus-baseline median deltas and percentile 95% bootstrap intervals (20,000 independent resamples per comparison, seed 1227):

| Capture delay | Preconnect buffer | Connected | Published/start returned | First decoded audio |
| --- | --- | ---: | ---: | ---: |
| 0 ms | off | +0 [-9, +7] | -7 [-18, +0] | +0 [-14, +7] |
| 0 ms | on | +1 [-4, +8] | +5 [-5, +13] | +0 [-2, +19] |
| 1000 ms | off | +8 [-26, +14] | -372 [-408, -369] | -376 [-407, -369] |
| 1000 ms | on | -1006 [-1095, -1001] | -379 [-457, -367] | -380 [-470, -368] |

Small controlled samples, unadjusted for multiple comparisons; not production tail or significance estimates. Immediate means zero injected capture delay, not zero device/SDK work.
