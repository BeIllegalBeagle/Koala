defmodule Koala.Nano.Block do
  @moduledoc """
  The block struct and associated functions.

  ## Fields

    * `type` - the block type, default: "send"
    * `previous` - the previous block hash, e.g. 9F1D53E732E48F25F94711D5B22086778278624F715D9B2BEC8FB81134E7C904
    * `destination` - the destination address, e.g. xrb_34bmpi65zr967cdzy4uy4twu7mqs9nrm53r1penffmuex6ruqy8nxp7ms1h1
    * `balance` - the amount to send, measured in RAW
    * `work` - the proof of work, e.g. "266063092558d903"
    * `signature` - the signed block digest/hash
    * `hash` - the block digest/hash
    * `source` - the source hash for a receive block
    * `representative` - the representative for an open block
    * `account` - the account for an open block
    * `state` - the state of the block, can be: `:unsent` or `:sent`

  ## Send a block

      alias Nano.{Block, Tools}

      seed = "9F1D53E732E48F25F94711D5B22086778278624F715D9B2BEC8FB81134E7C904"

      # Generate a private and public keypair from a wallet seed
      {priv, pub} = Tools.seed_account!(seed, 0)

      # Derives an "xrb_" address
      address = Tools.create_account!(pub)

      # Get the previous block hash
      {:ok, %{"frontier" => block_hash}} = Nano.account_info(address)

      # Somewhat counterintuitively 'balance' refers to the new balance not the
      # amount to be sent
      block = %Block{
        previous: block_hash,
        destination: "xrb_1aewtdjz8knar65gmu6xo5tmp7ijrur1fgtetua3mxqujh5z9m1r77fsrpqw",
        balance: 0
      }

      # Signs and broadcasts the block to the network
      block |> Block.sign(priv, pub) |> Block.send()

  Now *all the funds* from the first account have been transferred to:

  `"xrb_1aewtdjz8knar65gmu6xo5tmp7ijrur1fgtetua3mxqujh5z9m1r77fsrpqw"`

  ## Receive the most recent pending block

      alias Nano.{Block, Tools}

      seed = "9F1D53E732E48F25F94711D5B22086778278624F715D9B2BEC8FB81134E7C904"

      # Generate a private and public keypair from a wallet seed
      {priv, pub} = Tools.seed_account!(seed, 1)

      # Derives an "xrb_" account
      account = Tools.create_account!(pub)

      {:ok, %{"blocks" => [block_hash]}} = Nano.pending(account, 1)
      {:ok, %{"frontier" => frontier}} = Nano.account_info(account)

      block = %Block{
        type: "receive",
        previous: frontier,
        source: block_hash
      }

      block |> Block.sign(priv, pub) |> Block.process()

  ## Open an account

      seed = "9F1D53E732E48F25F94711D5B22086778278624F715D9B2BEC8FB81134E7C904"
      representative = "xrb_3arg3asgtigae3xckabaaewkx3bzsh7nwz7jkmjos79ihyaxwphhm6qgjps4"

      # Generate a private and public keypair from a wallet seed
      {priv_existing, pub_existing} = Tools.seed_account!(seed, 1)
      {priv_new, pub_new} = Tools.seed_account!(seed, 2)

      existing_account = Tools.create_account!(pub_existing)
      new_account = Tools.create_account!(pub_new)

      {:ok, %{"frontier" => block_hash, "balance" => balance}} = Nano.account_info(existing_account)

      # Convert to number
      {balance, ""} = Integer.parse(balance)

      # We need to generate a send block to the new address
      block = %Block{
        previous: block_hash,
        destination: new_account,
        balance: balance
      }

      # Signs and broadcasts the block to the network
      send_block = block |> Block.sign(priv_existing, pub_existing) |> Block.send()

      # The open block
      block = %Block{
        type: "open",
        account: new_account,
        source: send_block.hash,
        representative: representative
      }

      # Broadcast to the network
      open_block = block |> Block.sign(priv_new, pub_new) |> Block.process()

      ## ISSUES

      There is no warning for when the wallet is a block behind
      thus making invalid processing requests to the network

  """

  import Koala.Nano.Helpers

  alias Koala.Nano.{Block, Tools}
  alias Koala.Canoe, as: Canoe

  @doc """
    State block preamble
   """
  @preamble "0000000000000000000000000000000000000000000000000000000000000006"


##will have to add acnt_id for data.ex
  defstruct [
    type: nil,
    link: nil,
    hash: nil,
    previous: nil,
    balance: nil,
    amount: nil,
    work: nil,
    signature: nil,
    representative: nil,
    account: nil,
    state: :unsent
  ]

  defimpl Collectable, for: Block do
    def into(original) do
      {original, fn
        block, {:cont, {k, v}} when is_atom(k) -> %{block | k => v}
        block, {:cont, {k, v}} when is_binary(k) -> %{block | String.to_atom(k) => v}
        block, :done -> block
        _, :halt -> :ok
      end}
    end
  end

  @doc """
  Processes the block. Automatically invokes the correct processing function.
  """
  def process(%Block{type: {:error, _reason}} = block), do: block
  def process(%Block{type: "send"} = block), do: send(block)
  def process(%Block{type: "receive"} = block), do: recv(block)
  def process(%Block{type: "open"} = block), do: open(block)

  @doc """
  Signs the block. Automatically invokes the correct signing function. Raises
  `ArgumentError` if the type is not recognised.
  """
  def sign(block, priv_key, pub_key \\ nil)

  def sign(%Block{type: "send", state: :unsent} = block, priv_key, pub_key) do
    sign_send(block, priv_key, pub_key)
  end

  def sign(%Block{type: "receive", state: :unsent} = block, priv_key, pub_key) do
    sign_recv(block, priv_key, pub_key)
  end

  def sign(%Block{type: "open", state: :unsent} = block, priv_key, pub_key) do
    sign_open(block, priv_key, pub_key)
  end

  def sign(%Block{}, _priv, _pub) do
    raise ArgumentError, message: "unrecognised block type"
  end

  @doc """
  Signs a send block.
  """
  def sign_send(%Block{
    link: source_block,
    representative: representative,
    account: account,
    balance: balance,
    previous: previous
  } = block, priv_key, pub_key \\ nil) do

    balance = Integer.to_string(String.to_integer(balance), 16)
      |> Tools.raw_balance_hex

    [priv_key, pub_key, source_block, previous, preamble, balance] =
      if_string_hex_to_binary([priv_key, pub_key, source_block, previous, @preamble,
         balance])

     hash = Blake2.hash2b(
       preamble <>
       Tools.address_to_public!(account) <>
       previous <>
       Tools.address_to_public!(representative) <>
       balance <>
       source_block, 32
      )

    signature = Ed25519.signature(hash, priv_key, pub_key)
    %{block | hash: Base.encode16(hash), signature: Base.encode16(signature)}

  end

  @doc """
  Signs a receive block.
  """
  def sign_recv(%Block{
    link: source_block,
    representative: representative,
    account: account,
    balance: balance,
    previous: previous
  } = block, priv_key, pub_key \\ nil) do
    balance = Integer.to_string(String.to_integer(balance), 16)
      |> Tools.raw_balance_hex

    [priv_key, pub_key, source_block, previous, preamble, balance] =
      if_string_hex_to_binary([priv_key, pub_key, source_block, previous, @preamble, balance])

    hash = Blake2.hash2b(
      preamble <>
      Tools.address_to_public!(account) <>
      previous <>
      Tools.address_to_public!(representative) <>
      balance <>
      source_block, 32
    )
    signature = Ed25519.signature(hash, priv_key, pub_key)

    %{block | hash: Base.encode16(hash), signature: Base.encode16(signature)}
  end

  @doc """
  Signs an open block.
  """
  def sign_open(%Block{
    link: source_block,
    representative: representative,
    account: account,
    balance: balance,
    previous: previous
  } = block, priv_key, pub_key \\ nil) do
    balance = Integer.to_string(String.to_integer(balance), 16)
      |> Tools.raw_balance_hex

    [priv_key, pub_key, source_block, previous, preamble, balance] =
      if_string_hex_to_binary([priv_key, pub_key, source_block, previous, @preamble,
       balance])
      # {:ok, balance} = Koala.Nano.Tools.raw_to_units(String.to_integer(balance), :MXRB)
      # balance = Decimal.to_float(balance)

    hash = Blake2.hash2b(
      preamble <>
      Tools.address_to_public!(account) <>
      previous <>
      Tools.address_to_public!(representative) <>
      balance <>
      source_block, 32
    )

    signature = Ed25519.signature(hash, priv_key, pub_key)

    %{block | hash: Base.encode16(hash), signature: Base.encode16(signature)}
  end

  @doc """
  Sends a block.
  """
  def send(%Block{link: nil}), do: raise ArgumentError
  def send(%Block{signature: nil}), do: raise ArgumentError

  def send(%Block{
    previous: previous,
    state: :unsent
  } = block) do
    with {:ok, %{"work" => work}} <- Canoe.work_generate(previous),
         {:ok, %{}} <- Canoe.process(%{block | work: work, type: "state"})
         do
           %{block | work: work, state: :sent}
         else
           {:ok, message} ->
             IO.inspect(message)
             send(block)
           {:error, reason} ->
              %{block | state: {:error, reason}}
         end
  end

  @doc """
  Receives a block.
  """
  def recv(%Block{previous: previous} = block) do
    with {:ok, %{"work" => work}} <- Canoe.work_generate(previous),
         {:ok, %{}} <- Canoe.process(%{block | work: work, type: "state"})
         do
           %{block | work: work, state: :sent, type: "receive"}
         else
           {:ok, message} ->
             IO.inspect(message)
             send(block)
           {:error, reason} ->
              %{block | state: {:error, reason}}
         end
  end

  @doc """
  Opens a block.
  """
  def open(%Block{account: pub_key} = block) do

    work_target = pub_key |> Tools.address_to_public! |> Base.encode16

    with {:ok, %{"work" => work}} <- Canoe.work_generate(work_target),
         {:ok, %{}} <- Canoe.process(%{block | work: work, type: "state"})
         do
           ##The blocks hash needs added here for storage at
           ##
           %{block | work: work, state: :sent, type: "open"}
         else
           {:ok, message} ->
             IO.inspect(message)
             send(block)
           {:error, reason} ->
              %{block | state: {:error, reason}}
         end
  end

  @doc """
  Generates a `RaiEx.Block` struct from a map.
  """
  def from_map(%{} = map) do
    Enum.into(map, %Block{})
  end
end
