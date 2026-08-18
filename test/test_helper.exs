# Tests remain provider-free.
# Durable session tests share one crash-safe SQLite writer. Serial cases keep
# public one-second deadlines deterministic under fsync load on all CI targets.
ExUnit.start(assert_receive_timeout: 500, max_cases: 1)
