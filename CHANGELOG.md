# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [prerelease]

- Formulate an explicit support policy.
- Support Elixir 1.20 and Erlang/OTP 29.
- Drop support for Elixir 1.14, minimal supported version is now 1.15 (with OTP 25).

## [1.2.0]

### Changed

- **Internal refactor**: State is now stored in a typed record (`NoNoncense.State`) for improved maintainability.
- **Performance**: 64-bit counter is initialized with the startup timestamp, eliminating a redundant addition on each `nonce/2` call.
- **Performance**: Minor optimization in the `nonce/2` hot path.

### Other

- Updated dependencies.

## [1.1.3]

- Fixed documentation typos.
- Added link to Speck Rust crate docs.

## [1.1.2]

- Improved documentation.
- Extended CI to run on Windows and macOS.

## [1.1.1]

- Updated documentation to reflect that legacy ciphers (Blowfish, 3DES) are unavailable on Windows and macOS.

## [1.1.0]

- Add `encrypt/2`, `decrypt/2` and `encrypted_nonce/3`.

## [1.0.0]

### Breaking Changes

- **Encryption key management**: Encryption keys must now be provided at initialization via `NoNoncense.init/1` using the `:base_key` option (or individual `:key64`, `:key96`, `:key128` options). Keys are no longer passed to `encrypted_nonce/2`.
- **Default encryption algorithm changed**: The default encryption algorithm for 64-bit and 96-bit nonces has been changed from `:des3` to `:blowfish` for better performance and security.
- **Function signature change**: `encrypted_nonce/3` signature changed from `encrypted_nonce(name \\ __MODULE__, bit_size, key)` to `encrypted_nonce(name \\ __MODULE__, bit_size)`.

### Added

- **Speck cipher support**: Added optional support for the Speck cipher family via the `speck_ex` dependency, providing native block sizes for 64-bit, 96-bit, and 128-bit nonces with excellent performance.
- **Algorithm selection**: New options `:cipher64`, `:cipher96`, and `:cipher128` in `NoNoncense.init/1` allow choosing encryption algorithms per nonce size.
  - 64/96 bits: `:blowfish` (default), `:des3` and `:speck`
  - 128 bits: `:aes` (default) and `:speck`
- **Key derivation**: Automatic key derivation from `:base_key` using PBKDF2-HMAC-SHA256, eliminating the need to manage separate keys for each nonce size.

### Changed

- **Performance improvement**: Pre-initialization of encryption ciphers at startup provides huge performance gains.
- **Default algorithms**: 64-bit and 96-bit nonces now default to `:blowfish` instead of `:des3` for better performance and security.

### Migration Guide

See [MIGRATION.md](MIGRATION.md) for detailed migration instructions.

## [0.0.1 - 0.0.7]

Initial releases, changes were mainly performance improvements.
