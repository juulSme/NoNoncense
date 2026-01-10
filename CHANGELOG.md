# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
