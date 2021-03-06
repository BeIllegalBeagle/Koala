defmodule Koala.Nano.Tools do
  @moduledoc """
  This module provides convenience functions for interacting with the nano protocol and contructing blocks.
  """

  use Tesla
  use Task

  import Koala.Nano.Helpers

  alias Koala.Nano.Block
  alias Koala.Nano.Tools.Base32

  plug Tesla.Middleware.BaseUrl, "https://napi.nanoo.tools"
  plug Tesla.Middleware.JSON


  @delay 200
  @zero Decimal.new(0)
  @power_30 1000000000000000000000000000000
  @chx_1 10000000000000000000000000

  @units [
    GXRB: 1_000_000_000_000_000_000_000_000_000_000_000,
    MXRB: 1_000_000_000_000_000_000_000_000_000_000,
    kXRB: 1_000_000_000_000_000_000_000_000_000,
    CHX:  1_000_000_000_000_000_000_000_0000,
    mXRB: 1_000_000_000_000_000_000_000,
    uXRB: 1_000_000_000_000_000_000
  ]

  @prev_open "0000000000000000000000000000000000000000000000000000000000000000"

  @doc """
    Generates a wallet seed.
  """
  def seed do
    :crypto.strong_rand_bytes(32)
  end

  @doc """
    Generates an id to used for Canoe.
  """
  def mqtt_id do
    Base.encode16(:crypto.strong_rand_bytes(6))
  end

  @doc """
    Generates a longer token to used for Canoe
  """
  def mqtt_token do
    Base.url_encode64(:crypto.strong_rand_bytes(48))
  end



  @doc """
  Converts RaiBlocks raw amounts to metric prefixed amounts. The second argument
  to `raw_to_units/2` can optionally specify the minimum number of integer
  digits to occur in the converted amount. Alternatively if the second argument
  is one of `:GXRB`, `:MXRB`, `:kXRB`, `:XRB`, `:mXRB` or `:uXRB` then the raw
  amount will be converted to the relevant unit.

  ## Examples

      iex> raw_to_units(10000000000000000000)
      {#Decimal<10>, :uxrb}

      iex> raw_to_units(Decimal.new(10000000000000000000000))
      {#Decimal<10>, :mxrb}

      iex> raw_to_units(10000000000000000000000, 3)
      {#Decimal<10000>, :uxrb}

      iex> raw_to_units(10000000000000000000000, :xrb)
      #Decimal<0.01>

  """
  def raw_to_units(raw, min_digits \\ 1)
  def raw_to_units(raw, arg) when is_integer(raw) do
    raw_to_units(Decimal.new(raw), arg)
  end
  def raw_to_units(raw, unit) when is_atom(unit) do
    {Decimal.div(raw, Decimal.new(@units[unit] || 1)), unit}
  end
  def raw_to_units(raw, min_digits) do
    Enum.each(@units, fn {unit, _} ->
      {div, _} = raw_to_units(raw, unit)

      if integer_part_digits(div) >= min_digits do
        throw {div, unit}
      end
    end)

    {raw, :raw}
  catch
    result -> result
  end

  @doc """
    Converts various RaiBlocks units to raw units.
  """
  def units_to_raw(amount, unit) when is_integer(amount) do
    units_to_raw(Decimal.new(amount), unit)
  end
  def units_to_raw(amount, unit) do
    multiplier = @units[unit] || 1
    Decimal.mult(amount, Decimal.new(multiplier))
  end

  # Returns the number of digits in the integer part
  def integer_part_digits(@zero), do: 0
  def integer_part_digits(%Decimal{} = num) do
    rounded = Decimal.round(num, 0, :floor)

    if Decimal.cmp(rounded, @zero) !== :eq do
      rounded
      |> Decimal.to_string()
      |> String.length()
    else
      0
    end
  end

  @doc """
  Sends a block.
  """
  def raw_balance_hex(hex_balance) do
    if String.length(hex_balance) == 32 do
      hex_balance
    else
      hex_balance = "0" <> hex_balance
      raw_balance_hex(hex_balance)
    end

  end

  def length(hex_balance) do
    String.length(hex_balance) == 32
  end

  def accounts_pending(account) do

    {:ok, response} = get("/?action=accounts_pending&accounts=" <> account)
    IO.inspect response
    %{"blocks" => body} = response.body

  end

  @doc """
  This is an alternative to canoes pow generarion funcrion
  """
  #
  # def generate_PoW(hash) do
  #   {:ok, response} = get("/?action=work_generate&hash=" <> hash)
  #   case response.body do
  #     nil ->
  #         "0"
  #     bal ->
  #       {:ok, %{"work" =>  bal["work"]}}
  #     end
  # end
  #
  # @doc """
  # Does a network call to check whether or not the account in question is open.
  # Replaces the function in canoe as it was far too unreliable
  # """
  #
  # def is_open!(account) do
  #   {:ok, response} = get("?action=account_info&account=" <> account)
  #    !Map.has_key?(response.body, "error")
  # end
  #
  # @doc """
  # The same case as the function above. Returns balance in RAW
  # """
  #
  # def balance_from_address(address) do
  #   {:ok, response} = get("/?action=account_info&account=" <> address)
  #   case response.body
  #     |> Map.get("balance") do
  #     nil ->
  #         "0"
  #     bal ->
  #       bal
  #     end
  # end
  #
  # @doc """
  # The same case as the function above again
  # """
  #
  # def balance_from_hash (hash) do
  #   {:ok, response} = get("/?action=block_info&hash=" <> hash)
  #   response.body["amount"]
  # end

  def open_account({priv, pub}, source) do
    # The open block
    amount = Koala.Canoe.amount_from_hash(source)
    block =
      %Block{
        balance: amount,
        amount: amount,
        previous: @prev_open,
        link: source,
        type: "open",
        account: create_account!(pub),
        representative: Application.get_env(:rai_ex, :representative,
            "nano_3pczxuorp48td8645bs3m6c3xotxd3idskrenmi65rbrga5zmkemzhwkaznh")
      }
      |> Block.sign(priv, pub)
      |> Block.process()

    {:ok, block}
  end

  def receive({priv, pub}, source, frontier_block_hash) do
    # The open block
    amount = Koala.Canoe.amount_from_hash(source)

    balance = create_account!(pub)
      |> Koala.Canoe.balance_from_address
      |> String.to_integer

    block =
      %Block{
        balance: Integer.to_string(balance + String.to_integer(amount)),
        amount: amount,
        previous: frontier_block_hash,
        link: source,
        type: "receive",
        account: create_account!(pub),
        representative: Application.get_env(:rai_ex, :representative,
            "nano_3pczxuorp48td8645bs3m6c3xotxd3idskrenmi65rbrga5zmkemzhwkaznh")
      }
      |> Block.sign(priv, pub)
      |> Block.process()

    {:ok, block}
  end

  def send({priv, pub}, recipient, chx \\ 10000000000000000000000000, frontier_block_hash) do
    # The open block
    address = create_account!(pub)
    balance = address
      |> Koala.Canoe.balance_from_address
      |> String.to_integer

    block =
      %Block{
        balance: Integer.to_string(balance - chx),
        amount: chx,
        previous: frontier_block_hash,
        link: Base.encode16((address_to_public!(recipient))),
        type: "send",
        account: address,
        representative: Application.get_env(:rai_ex, :representative,
            "nano_3pczxuorp48td8645bs3m6c3xotxd3idskrenmi65rbrga5zmkemzhwkaznh")
      }
      |> Block.sign(priv, pub)
      |> Block.process()

      IO.inspect(block)

    {:ok, block}
  end


  @doc """
  Calculates and compares the checksum on an address, returns a boolean.

  ## Examples

      iex> address_valid("xrb_34bmpi65zr967cdzy4uy4twu7mqs9nrm53r1penffmuex6ruqy8nxp7ms1h1")
      true

      iex> address_valid("clearly not valid")
      false

  """
  def account_valid?(address) do
    {_pre, checksum} =
      address
      |> String.trim("xrb_")
      |> String.split_at(-8)

    try do
      computed_checksum =
        address
        |> address_to_public!()
        |> hash_checksum!()

      attached_checksum = checksum |> Base32.decode!() |> reverse()

      computed_checksum == attached_checksum
    rescue
      _ -> false
    end
  end

  @doc """
  Converts a Nano address to a public key.
  """
  def address_to_public!(address) do
    binary = address_to_public_without_trim!(address)
    binary_part(binary, 0, byte_size(binary) - 5)
  end

  @doc """
  Same as `Nano.Tools.address_to_public!` except leaves untrimmied 5 bytes at end of binary.
  """
  def address_to_public_without_trim!(address) do

    pub_key = case String.starts_with?(address, "xrb_") do

      true ->
        binary =
          address
          |> String.trim("xrb_")
          |> Base32.decode!()

        <<_drop::size(4), pub_key::binary>> = binary

        pub_key

      false ->
        binary =
          address
          |> String.trim("nano_")
          |> Base32.decode!()

        <<_drop::size(4), pub_key::binary>> = binary

        pub_key
    end


  end

  @doc """
  Creates an address from the given *public key*. The address is encoded in
  base32 as defined in `Nano.Tools.Base32` and appended with a checksum.

  ## Examples

      iex> create_account!(<<125, 169, 163, 231, 136, 75, 168, 59, 83, 105, 128, 71, 82, 149, 53, 87, 90, 35, 149, 51, 106, 243, 76, 13, 250, 28, 59, 128, 5, 181, 81, 116>>)
      "xrb_1zfbnhmrikxa9fbpm149cccmcott6gcm8tqmbi8zn93ui14ucndn93mtijeg"

      iex> create_address!("7DA9A3E7884BA83B53698047529535575A2395336AF34C0DFA1C3B8005B55174")
      "xrb_1zfbnhmrikxa9fbpm149cccmcott6gcm8tqmbi8zn93ui14ucndn93mtijeg"

  """
  def create_account!(pub_key) do
    # This allows both a binary input or hex string
    pub_key =
      pub_key
      |> if_string_hex_to_binary()
      |> right_pad_binary(256 - bit_size(pub_key))

    encoded_check =
      pub_key
      |> hash_checksum!()
      |> reverse()
      |> Base32.encode!()

    encoded_address =
      pub_key
      |> left_pad_binary(4)
      |> Base32.encode!()

    "nano_#{encoded_address <> encoded_check}"
  end

  @doc """
  Derives the public key from the private key.

  ## Examples

      iex> derive_public!(<<84, 151, 51, 84, 136, 206, 7, 211, 66, 222, 10, 240, 159, 113, 36, 98, 93, 238, 29, 96, 95, 8, 33, 62, 53, 162, 139, 52, 75, 123, 38, 144>>)
      <<125, 169, 163, 231, 136, 75, 168, 59, 83, 105, 128, 71, 82, 149, 53, 87, 90, 35, 149, 51, 106, 243, 76, 13, 250, 28, 59, 128, 5, 181, 81, 116>>

      iex> derive_public!("5497335488CE07D342DE0AF09F7124625DEE1D605F08213E35A28B344B7B2690")
      <<125, 169, 163, 231, 136, 75, 168, 59, 83, 105, 128, 71, 82, 149, 53, 87, 90, 35, 149, 51, 106, 243, 76, 13, 250, 28, 59, 128, 5, 181, 81, 116>>

  """
  def derive_public!(priv_key) do
    # This allows both a binary input or hex string
    priv_key = if_string_hex_to_binary(priv_key)

    Ed25519.derive_public_key(priv_key)
  end

  @doc """
  Generates the public and private keys for a given *wallet*.

  ## Examples

      iex> seed_account!("8208BD79655E7141DCFE792084AB6A8FDFFFB56F37CE30ADC4C2CC940E276A8B", 0)
      {pub, priv}

  """
  def seed_account!(seed, nonce) do
    # This allows both a binary input or hex string
    seed = if_string_hex_to_binary(seed)

    priv = Blake2.hash2b(seed <> <<nonce::size(32)>>, 32)
    pub  = derive_public!(priv)

    {priv, pub}
  end

  defp hash_checksum!(check) do
    Blake2.hash2b(check, 5)
  end
end
