#!/usr/bin/env elixir
#
# Partyline over the public mesh, using the interfaces configured in
# ~/.config/reticulum_ex.toml (same as hailer).
#
# Browse: print every lxst.room announce heard, decoded.
#   mix run examples/partyline_client.exs [--minutes 60]
#
# Join text-only and chat from stdin:
#   mix run examples/partyline_client.exs HASH [--name NAME] [--room ROOM]
#
# --hub HOST:PORT (repeatable) uses those TCP hubs instead of the toml,
# e.g. --hub rr.rns.moscow:4242 for the rns.moscow community server
# (1667b0e916759716ebb26e5d9d3a2c7e).
#
#   Lines are sent as chat. Commands: /who, /rooms, /join ROOM, /quit
#
# --listen joins read-only but not deafened: muted, nothing sent, chat
# lines refused, and relayed audio summarized every 10 s per speaker
# (codec, frame size and duration, sequence gaps). Without it the session
# is text-only and the server sends no audio at all.
#
# --path-wait MINUTES (default 1) waits that long for a path: a path reply
# or the server's own announce, which comes at most every 55 minutes.
#
# Servers re-announce every 55 minutes, so browsing can take a while to
# hear a given server.

require Logger
Logger.configure(level: :warning)

defmodule PartylineExample do
  alias Partyline.{Client, Transport}
  alias Partyline.Protocol.{AnnounceData, Assignment, Channel, User}

  def main(argv) do
    {opts, args, _} =
      OptionParser.parse(argv,
        strict: [
          name: :string,
          room: :string,
          minutes: :integer,
          hub: :keep,
          listen: :boolean,
          path_wait: :integer
        ]
      )

    start_rns(Keyword.get_values(opts, :hub))

    case args do
      [] -> browse(Keyword.get(opts, :minutes, 60))
      [hash | _] -> join(hash, opts)
    end
  end

  defp start_rns(hubs) do
    # No --hub: nil makes RNS.Config.parse/0 read ~/.config/reticulum_ex.toml.
    config =
      case hubs do
        [] ->
          nil

        hubs ->
          # Same shape as the decoded reticulum_ex.toml.
          interfaces =
            for hub <- hubs, into: %{} do
              [host, port] = String.split(hub, ":", parts: 2)
              {hub, %{"type" => "TCPClient", "host" => host, "port" => String.to_integer(port)}}
            end

          IO.puts("Hubs: #{Enum.join(hubs, ", ")}")
          {:ok, config} = RNS.Config.parse(%{"interfaces" => interfaces})
          config
      end

    {:ok, _} = RNS.Reticulum.start_link(config, wait: true)

    if Process.whereis(RNS.Link.Registry) == nil do
      {:ok, _} = RNS.Link.Registry.start_link()
    end

    :ok
  end

  # ==========================================================================
  # Browse
  # ==========================================================================

  @heartbeat_ms 30_000

  defp browse(minutes) do
    :ok = Transport.subscribe_announces(Partyline.Transport.RNS)

    # Also count every announce of any kind, so a quiet run can be told
    # apart from a dead mesh connection.
    RNS.AnnounceHashStore.add_handler(nil, nil, self())
    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    deadline = now() + minutes * 60_000
    IO.puts("Listening for lxst.room announces for #{minutes} min...")
    browse_loop(deadline, %{seen: %{}, total: 0})
  end

  defp browse_loop(deadline, st) do
    left = deadline - now()

    if left <= 0 do
      summary(st.seen)
    else
      receive do
        {:partyline_announce, announce} ->
          hex = Base.encode16(announce.destination_hash, case: :lower)
          line = describe(announce)

          if st.seen[hex] != line do
            IO.puts("#{clock()}  #{hex}  #{line}")
          end

          browse_loop(deadline, put_in(st.seen[hex], line))

        {:announce, _destination} ->
          browse_loop(deadline, %{st | total: st.total + 1})

        :heartbeat ->
          IO.puts("#{clock()}  [mesh] #{st.total} announces heard, #{map_size(st.seen)} partyline")
          Process.send_after(self(), :heartbeat, @heartbeat_ms)
          browse_loop(deadline, st)
      after
        left -> summary(st.seen)
      end
    end
  end

  defp describe(announce) do
    case AnnounceData.unpack(announce.app_data) do
      {:ok, info} ->
        flags =
          [
            AnnounceData.hidden?(info) && "hidden",
            AnnounceData.password?(info) && "password",
            AnnounceData.allowlist?(info) && "allowlist"
          ]
          |> Enum.filter(& &1)
          |> Enum.join(",")

        locale = [info.language, info.country] |> Enum.reject(&(&1 == "")) |> Enum.join("/")

        [
          info.name || "(hidden)",
          "hops=#{announce.hops}",
          "proto=#{info.version}",
          flags,
          locale,
          info.description
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("  ")

      :error ->
        "undecodable app_data #{inspect(announce.app_data)}"
    end
  end

  defp summary(seen) do
    IO.puts("\n#{map_size(seen)} server(s) heard:")
    for {hex, line} <- seen, do: IO.puts("  #{hex}  #{line}")
  end

  # ==========================================================================
  # Join
  # ==========================================================================

  @report_ms 10_000

  defp join(hash_hex, opts) do
    {:ok, hash} = Base.decode16(String.trim(hash_hex), case: :mixed)
    listen = Keyword.get(opts, :listen, false)

    # Fresh identity per run. The server evicts older sessions of the same
    # identity, so this never collides with a reference client of ours.
    identity = RNS.Identity.new()
    IO.puts("Identity #{Base.encode16(RNS.Identity.hash(identity), case: :lower)}")
    IO.puts("Resolving path to #{String.downcase(hash_hex)}...")

    {:ok, client} =
      Client.start_link(
        destination_hash: hash,
        name: Keyword.get(opts, :name, "partyline_ex"),
        room: opts[:room],
        identity: identity,
        # Listening: muted, so the server knows we won't talk; not deaf, so
        # it relays audio to us.
        text_only: not listen,
        muted: listen,
        deaf: false,
        path_timeout: Keyword.get(opts, :path_wait, 1) * 60_000
      )

    if listen, do: Process.send_after(self(), :report, @report_ms)
    spawn_link(fn -> stdin_loop(client, listen) end)
    event_loop(client, %{})
  end

  # Reads stdin until /quit or EOF; event_loop/2 exits on the :closed
  # event that disconnect produces.
  defp stdin_loop(client, listen) do
    case IO.gets("") do
      line when is_binary(line) ->
        line = String.trim(line)

        if listen and line != "" and not String.starts_with?(line, "/"),
          do: IO.puts("! read-only (--listen): not sent"),
          else: command(client, line)

        if line != "/quit", do: stdin_loop(client, listen)

      _eof_or_error ->
        Client.disconnect(client)
    end
  end

  defp command(_client, ""), do: :ok
  defp command(client, "/quit"), do: Client.disconnect(client)

  defp command(client, "/who") do
    info = Client.info(client)

    for {_id, u} <- Enum.sort(info.users) do
      room = info.channels[u.room]
      IO.puts("  #{u.name}  #{room && room.name}#{flags(u)}")
    end
  end

  defp command(client, "/rooms") do
    for {_id, c} <- Enum.sort(Client.info(client).channels), do: IO.puts(channel_line(c))
  end

  defp command(client, "/join " <> name) do
    info = Client.info(client)
    key = name |> String.trim() |> String.downcase()

    case Enum.find(Map.values(info.channels), &(String.downcase(&1.name) == key)) do
      nil -> IO.puts("! no room #{name}")
      channel -> Client.move(client, channel.id)
    end
  end

  defp command(client, text) do
    case Client.send_text(client, text) do
      :ok -> IO.puts("#{clock()} <me> #{text}")
      {:error, reason} -> IO.puts("! not sent: #{inspect(reason)}")
    end
  end

  defp event_loop(client, stats) do
    receive do
      {:partyline, ^client, {:closed, info}} ->
        report(client, stats)
        IO.puts("#{clock()} closed: #{info.error || inspect(info.reason)}#{if info.kicked?, do: " (refused)"}")

      {:partyline, ^client, {:frames, speaker, frames, seq}} ->
        event_loop(client, count_frames(stats, speaker, frames, seq))

      {:partyline, ^client, event} ->
        print(client, event)
        event_loop(client, stats)

      :report ->
        report(client, stats)
        Process.send_after(self(), :report, @report_ms)
        event_loop(client, %{})
    end
  end

  # Per speaker, per report interval.
  defp count_frames(stats, speaker, frames, seq) do
    s =
      Map.get(stats, speaker, %{
        packets: 0,
        frames: 0,
        bad: 0,
        bytes: 0,
        min: nil,
        max: 0,
        kinds: MapSet.new(),
        next_seq: nil,
        gaps: 0
      })

    good = Enum.filter(frames, &is_binary/1)
    sizes = Enum.map(good, &byte_size/1)
    kinds = Enum.reduce(good, s.kinds, &MapSet.put(&2, frame_kind(&1)))

    # A sequence that skips ahead of the expected one counts its gap.
    gaps =
      case {s.next_seq, seq} do
        {nil, _} -> s.gaps
        {_, nil} -> s.gaps
        {expected, seq} -> s.gaps + Bitwise.band(seq - expected, 0xFFFF) |> min_gap()
      end

    next_seq = if seq, do: Bitwise.band(seq + length(frames), 0xFFFF), else: s.next_seq

    Map.put(stats, speaker, %{
      s
      | packets: s.packets + 1,
        frames: s.frames + length(good),
        bad: s.bad + length(frames) - length(good),
        bytes: s.bytes + Enum.sum(sizes),
        min: Enum.min([s.min || :infinity | sizes], fn -> s.min end),
        max: Enum.max([s.max | sizes]),
        kinds: kinds,
        next_seq: next_seq,
        gaps: gaps
    })
  end

  # Late or repeated frames wrap to a huge forward distance; not a gap.
  defp min_gap(d) when d > 0x8000, do: 0
  defp min_gap(d), do: d

  # Codec plus, for Codec2, the mode header; and the frame duration.
  defp frame_kind(<<2, mode, _::binary>> = frame) do
    "codec2/#{c2_mode(mode)} #{Partyline.Profile.frame_duration_ms(frame)}ms"
  end

  defp frame_kind(frame) do
    "#{Partyline.Profile.codec_of(frame) || "unknown"} #{Partyline.Profile.frame_duration_ms(frame) || "?"}ms"
  end

  defp c2_mode(header) do
    case Partyline.Profile.codec2_mode_for_header(header) do
      {:ok, %{mode: mode}} -> mode
      :error -> "0x#{Integer.to_string(header, 16)}"
    end
  end

  defp report(_client, stats) when map_size(stats) == 0, do: :ok

  defp report(client, stats) do
    users = Client.info(client).users

    for {speaker, s} <- Enum.sort(stats) do
      name = (users[speaker] && users[speaker].name) || "##{speaker}"
      kbps = Float.round(s.bytes * 8 / (@report_ms / 1_000) / 1_000, 1)

      IO.puts(
        "#{clock()} ~ #{name}: #{s.frames} frames in #{s.packets} pkts, " <>
          "#{s.min}-#{s.max} B, #{kbps} kbps, #{Enum.join(s.kinds, ", ")}, " <>
          "seq gaps #{s.gaps}#{if s.bad > 0, do: ", #{s.bad} non-bin"}"
      )
    end
  end

  defp print(_c, {:connected, i}),
    do: IO.puts("#{clock()} connected to #{i.name} (server #{i.app}, member ##{i.sid})\n  motd: #{i.motd}")

  defp print(_c, {:version, app}), do: IO.puts("  note: server runs Partyline #{app}")
  defp print(_c, {:channel, c}), do: IO.puts(channel_line(c))
  defp print(_c, {:channel_gone, c}), do: IO.puts("#{clock()} room removed: #{c.name}")
  defp print(_c, {:user_joined, u}), do: IO.puts("#{clock()} + #{u.name}#{flags(u)}")
  defp print(_c, {:user_left, u}), do: IO.puts("#{clock()} - #{u.name}")

  defp print(c, {:user_moved, u, _from}),
    do: IO.puts("#{clock()} > #{u.name} moved to #{room_name(c, u.room)}")

  defp print(_c, {:user_state, _u, _prev}), do: :ok
  defp print(_c, :synced), do: IO.puts("#{clock()} synced")
  defp print(_c, {:room, nil}), do: IO.puts("#{clock()} in no room")

  defp print(c, {:room, %Assignment{} = a}),
    do: IO.puts("#{clock()} in room #{room_name(c, a.room_id)} [#{a.profile}]")

  defp print(_c, {:denied, nil, reason}), do: IO.puts("#{clock()} refused: #{reason}")
  defp print(c, {:denied, id, reason}), do: IO.puts("#{clock()} denied #{room_name(c, id)}: #{reason}")
  defp print(_c, {:notice, text}), do: IO.puts("#{clock()} * #{text}")
  defp print(_c, {:text, u, id, text}), do: IO.puts("#{clock()} <#{(u && u.name) || "##{id}"}> #{text}")
  defp print(_c, {:poke, u, id, text}), do: IO.puts("#{clock()} poke from #{(u && u.name) || "##{id}"}: #{text}")
  defp print(_c, {:motd, motd}), do: IO.puts("#{clock()} motd: #{motd}")
  defp print(_c, {:malformed, field, value}), do: IO.puts("#{clock()} ! malformed field #{field}: #{inspect(value, limit: 8)}")
  defp print(_c, _other), do: :ok

  defp channel_line(%Channel{} = c) do
    extras =
      [
        Channel.ptt?(c) && "ptt",
        Channel.broadcast?(c) && "broadcast",
        Channel.requires_password?(c) && "password",
        Channel.requires_allowlist?(c) && "allowlist",
        Channel.requires_identity?(c) && not Channel.requires_allowlist?(c) && "identified"
      ]
      |> Enum.filter(& &1)

    tag = if extras == [], do: "", else: " (#{Enum.join(extras, ", ")})"
    desc = if c.description == "", do: "", else: "  #{c.description}"
    "  room #{c.id}: #{c.name} [#{c.profile}]#{tag}#{desc}"
  end

  defp flags(%User{} = u) do
    f =
      [
        u.operator && "op",
        u.text_only && "text",
        u.server_muted && "server-muted",
        u.muted && not u.text_only && "muted",
        u.deaf && not u.text_only && "deaf"
      ]
      |> Enum.filter(& &1)

    if f == [], do: "", else: " [#{Enum.join(f, ",")}]"
  end

  defp room_name(client, id) do
    case Client.info(client).channels[id] do
      nil -> "##{id}"
      c -> c.name
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp clock do
    {{_, _, _}, {h, m, s}} = :calendar.local_time()
    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end
end

PartylineExample.main(System.argv())
