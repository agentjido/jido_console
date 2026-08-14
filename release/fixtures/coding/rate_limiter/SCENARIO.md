# Rate limiter defect

Fix the implementation so that it satisfies all tests.

The function receives the timestamps of previously accepted events, the current
timestamp, a positive event limit, and a positive window size.

Required behavior:

- An event is accepted only when fewer than `limit` accepted events remain in
  the active window.
- A rejected event is not added to the stored timestamps.
- A timestamp exactly at `now - window_ms` is expired.
- The returned timestamps contain only active accepted events.

Make the smallest clear change. Do not change the tests.
