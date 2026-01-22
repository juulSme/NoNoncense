defmodule NoNoncense.Crypto do
  @moduledoc false
  use NoNoncense.Constants

  @base_opts %{
    base_key: nil,
    key64: nil,
    key96: nil,
    key128: nil,
    cipher64: :blowfish,
    cipher96: :blowfish,
    cipher128: :aes
  }

  def init(opts) do
    opts = Enum.into(opts, @base_opts)
    %{base_key: base_key} = opts

    verify_base_key(base_key)
    opts |> Map.take([:cipher64, :cipher96, :cipher128]) |> Enum.each(&verify_speck_loaded/1)

    key_alg_64 = maybe_gen_key(opts.key64, base_key, opts.cipher64, 64) |> maybe_init_cipher()
    key_alg_96 = maybe_gen_key(opts.key96, base_key, opts.cipher96, 96) |> maybe_init_cipher()
    key_alg_128 = maybe_gen_key(opts.key128, base_key, opts.cipher128, 128) |> maybe_init_cipher()

    {key_alg_64, key_alg_96, key_alg_128}
  end

  defp verify_base_key(key) do
    is_nil(key) or bit_size(key) >= 256 or
      raise ArgumentError, "base_key size must be at least 256 bits"
  end

  defp verify_speck_loaded({_map_key, alg}) do
    alg != :speck or Code.ensure_loaded?(SpeckEx) or
      raise ArgumentError, "you need optional dependency :speck_ex to use the speck cipher"
  end

  # Generate keys for nonce encryption if a base key or override is specified
  def maybe_gen_key(key, base_key, alg, nonce_size)
  def maybe_gen_key(nil, nil, _, _), do: nil

  def maybe_gen_key(nil, base_key, :blowfish, 64),
    do: {:blowfish, gen_key(base_key, "blowfish_64", 16)}

  def maybe_gen_key(nil, base_key, :blowfish, 96),
    do: {:blowfish, gen_key(base_key, "blowfish_96", 16)}

  def maybe_gen_key(nil, base_key, :des3, 64), do: {:des3, gen_key(base_key, "des3_64", 24)}
  def maybe_gen_key(nil, base_key, :des3, 96), do: {:des3, gen_key(base_key, "des3_96", 24)}
  def maybe_gen_key(nil, base_key, :aes, 128), do: {:aes, gen_key(base_key, "aes", 32)}

  def maybe_gen_key(nil, base_key, :speck, 64),
    do: {:speck, gen_key(base_key, "speck64_128", 16)}

  def maybe_gen_key(nil, base_key, :speck, 96),
    do: {:speck, gen_key(base_key, "speck96_144", 18)}

  def maybe_gen_key(nil, base_key, :speck, 128),
    do: {:speck, gen_key(base_key, "speck128_256", 32)}

  def maybe_gen_key(<<_::128>> = key, _, :blowfish, 64), do: {:blowfish, key}

  def maybe_gen_key(_, _, :blowfish, 64),
    do: raise(ArgumentError, "blowfish key size must be 128 bits")

  def maybe_gen_key(<<_::128>> = key, _, :blowfish, 96), do: {:blowfish, key}

  def maybe_gen_key(_, _, :blowfish, 96),
    do: raise(ArgumentError, "blowfish key size must be 128 bits")

  def maybe_gen_key(<<_::192>> = key, _, :des3, 64), do: {:des3, key}
  def maybe_gen_key(_, _, :des3, 64), do: raise(ArgumentError, "des3 key size must be 192 bits")
  def maybe_gen_key(<<_::192>> = key, _, :des3, 96), do: {:des3, key}
  def maybe_gen_key(_, _, :des3, 96), do: raise(ArgumentError, "des3 key size must be 192 bits")
  def maybe_gen_key(<<_::256>> = key, _, :aes, 128), do: {:aes, key}
  def maybe_gen_key(_, _, :aes, 128), do: raise(ArgumentError, "aes key size must be 256 bits")
  def maybe_gen_key(<<_::128>> = key, _, :speck, 64), do: {:speck, key}

  def maybe_gen_key(_, _, :speck, 64),
    do: raise(ArgumentError, "speck64 key size must be 128 bits")

  def maybe_gen_key(<<_::144>> = key, _, :speck, 96), do: {:speck, key}

  def maybe_gen_key(_, _, :speck, 96),
    do: raise(ArgumentError, "speck96 key size must be 144 bits")

  def maybe_gen_key(<<_::256>> = key, _, :speck, 128), do: {:speck, key}

  def maybe_gen_key(_, _, :speck, 128),
    do: raise(ArgumentError, "speck128 key size must be 256 bits")

  def maybe_gen_key(_, _, alg, size),
    do: raise(ArgumentError, "alg #{alg} is not supported for #{size}-bit nonces")

  # the IV-less ciphers that we use can be pre-initialized
  defp maybe_init_cipher(alg_key_pair)

  defp maybe_init_cipher({:aes, key}) do
    {:aes, :crypto.crypto_init(:aes_256_ecb, key, true),
     :crypto.crypto_init(:aes_256_ecb, key, false)}
  end

  defp maybe_init_cipher({:blowfish, key}) do
    {:blowfish, :crypto.crypto_init(:blowfish_ecb, key, true),
     :crypto.crypto_init(:blowfish_ecb, key, false)}
  end

  defp maybe_init_cipher({:des3, key}), do: {:des3, key, nil}

  if Code.ensure_loaded?(SpeckEx) do
    defp maybe_init_cipher({:speck, <<_::128>> = key}),
      do: {:speck, SpeckEx.Block.init(key, :speck64_128), nil}

    defp maybe_init_cipher({:speck, <<_::144>> = key}),
      do: {:speck, SpeckEx.Block.init(key, :speck96_144), nil}

    defp maybe_init_cipher({:speck, <<_::256>> = key}),
      do: {:speck, SpeckEx.Block.init(key, :speck128_256), nil}
  end

  defp maybe_init_cipher(_), do: {nil, nil, nil}

  defp gen_key(base, salt, length) do
    :crypto.pbkdf2_hmac(:sha256, base, salt, 1000, length)
  end

  if Code.ensure_loaded?(SpeckEx) do
    defdelegate speck_enc(nonce, cipher, variant), to: SpeckEx.Block, as: :encrypt
    defdelegate speck_dec(nonce, cipher, variant), to: SpeckEx.Block, as: :decrypt
  else
    def speck_enc(_nonce, _cipher, _variant) do
      raise(ArgumentError, "you need optional dependency :speck_ex to use the speck cipher")
    end

    def speck_dec(_nonce, _cipher, _variant) do
      raise(ArgumentError, "you need optional dependency :speck_ex to use the speck cipher")
    end
  end

  def crypt(nonce, cipher, enc_key_or_ref, dec_key_or_ref, encrypt?)
  def crypt(_, nil, _, _, _), do: raise(RuntimeError, "no key set at NoNoncense initialization")

  # 64-bit Speck
  def crypt(<<n::binary-8>>, :speck, ref, _, true), do: speck_enc(n, ref, :speck64_128)
  def crypt(<<n::binary-8>>, :speck, ref, _, false), do: speck_dec(n, ref, :speck64_128)

  # 64-bit Blowfish
  def crypt(<<n::binary-8>>, :blowfish, e_ref, _, true), do: :crypto.crypto_update(e_ref, n)
  def crypt(<<n::binary-8>>, :blowfish, _, d_ref, false), do: :crypto.crypto_update(d_ref, n)

  # 64-bit 3DES
  def crypt(<<n::binary-8>>, :des3, key, _, encrypt?), do: des_crypt(n, key, encrypt?)

  # 96-bit Speck
  def crypt(<<n::binary-12>>, :speck, ref, _, true), do: speck_enc(n, ref, :speck96_144)
  def crypt(<<n::binary-12>>, :speck, ref, _, false), do: speck_dec(n, ref, :speck96_144)

  # 96-bit Blowfish
  def crypt(<<n::binary-8, @zero32>>, :blowfish, e_ref, _, true),
    do: :crypto.crypto_update(e_ref, n) <> @zero32

  def crypt(<<n::binary-8, @zero32>>, :blowfish, _, d_ref, false),
    do: :crypto.crypto_update(d_ref, n) <> @zero32

  # 96-bit 3DES
  def crypt(<<n::binary-8, @zero32>>, :des3, key, _, encrypt?),
    do: des_crypt(n, key, encrypt?) <> @zero32

  # 128-bit AES
  def crypt(<<n::binary-16>>, :aes, e_ref, _, true), do: :crypto.crypto_update(e_ref, n)
  def crypt(<<n::binary-16>>, :aes, _, d_ref, false), do: :crypto.crypto_update(d_ref, n)

  # 128-bit Speck
  def crypt(<<n::binary-16>>, :speck, ref, _, true), do: speck_enc(n, ref, :speck128_256)
  def crypt(<<n::binary-16>>, :speck, ref, _, false), do: speck_dec(n, ref, :speck128_256)

  @des_iv <<0::64>>

  @compile {:inline, des_crypt: 3}
  defp des_crypt(nonce, key, encrypt?) do
    :crypto.crypto_one_time(:des_ede3_cbc, key, @des_iv, nonce, encrypt?)
  end
end
