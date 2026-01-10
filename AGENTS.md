Quick pointers

- Language: Elixir (mix project). Entry point: `lib/no_noncense.ex`.
- Tests: run `mix test` as a bash command.

Architecture & important concepts

- State storage: `NoNoncense.init/1` stores runtime state in `:persistent_term` and counters in `:atomics` (see `lib/no_noncense.ex`). Do not convert to a GenServer — the design intentionally uses low-level atomics and persistent term for performance.
- Nonce kinds:
  - `nonce/2` (counter nonces) — fast counter-based, uses `:atomics` for global counter and may `wait_until/2` to avoid producing nonces that predate their timestamp.
  - `sortable_nonce/2` (snowflake-like) — timestamp first, uses `:atomics` sortable counter. At high rates it may spin to wait for millisecond boundary; this is intentional for throughput.
  - `encrypted_nonce/2` — uses block ciphers to make counter nonces unpredictable (Blowfish, 3DES, AES, optional Speck using dependency SpeckEx).

Performance-sensitive patterns

- The code intentionally pre-initializes IV-less ciphers and stores their initialized contexts in `:persistent_term` for speed (see `NoNoncense.Crypto.maybe_init_cipher/1`). Be cautious: changing the initialization strategy affects performance and uniqueness guarantees.
- `:atomics` counters are used for high-rate concurrent generation. Small changes (sleep/yield) can drastically change throughput; tests/benchmarks in `bench/nonces.exs` document expected numbers.

Conventions & project-specific rules

- Do not change `:persistent_term` state at runtime except in tests — initialization is expected to happen at application start.
- Encryption keys: `:base_key` (>= 256 bits) is the primary source; `:key64/:key96/:key128` are optional overrides. See `NoNoncense.Crypto.maybe_gen_key/4` for allowed sizes.
- Optional deps: `:speck_ex` and `:redix` exist but are optional; guard code checks `Code.ensure_loaded?` before using them.
- Benchmarks and tests use tight concurrency; avoid adding global locks or sleeps in hot paths.

Common debugging locations

- `lib/no_noncense.ex` — main logic for nonce generation and timing behavior.
- `lib/no_noncense/crypto.ex` — key derivation, cipher init and Speck bindings.
- `test/no_noncense_test.exs` — comprehensive behavior tests and concurrency checks; use it as canonical examples for correct behavior.

Always use Tidewave's tools for evaluating code, querying the database, etc.

Use `get_docs` to access documentation, the `get_source_location` tool to
find module/function definitions, `project_eval` to run code etc.
