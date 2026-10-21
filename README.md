# partyline_ex

Partyline group voice over Reticulum for Elixir, built on
[reticulum_ex](https://codeberg.org/heroeslament/reticulum_ex). Targets wire
compatibility with [RFnexus/partyline](https://github.com/RFnexus/partyline)
protocol version 1 (reference app 1.0.5, LXST 0.5.4).

## Status

- [x] Transport layer (`Partyline.Transport`), RNS and loopback adapters
- [x] Protocol: field codec, records, text sanitizing, announce app_data,
      codec profiles and frame validation, MDU batching rules
- [x] Client session (`Partyline.Client`)
- [x] Server (`Partyline.Server`): admission, rooms, relay, chat, operators
- [x] Client joins the reference 1.0.5 server over the public mesh
      (rns.moscow), text-only
- [ ] Our server against the reference client over a live RNS interface
- [ ] Untagged Resource transfers (operator room add/edit/remove)
- [ ] Dial-in (LXST telephony)
- [ ] Audio pipeline (codecs, jitter buffer, playout): separate library

## Layout

```
lib/partyline/transport.ex            behaviour, event contract, facade
lib/partyline/transport/rns.ex        reticulum_ex adapter
lib/partyline/transport/rns/          GenLink bridges, listener, announce relay
lib/partyline/transport/loopback.ex   in-memory adapter for tests
lib/partyline/protocol.ex             wire encode/decode
lib/partyline/protocol/               records, text, announce data, batching
lib/partyline/profile.ex              codec profiles, frame validation
lib/partyline/client.ex               client session
lib/partyline/server.ex               server
lib/partyline/server/                 room and member state
```

## Wire notes

- Encoded packets are byte-identical to the reference's: fields are packed
  in the reference's dict insertion order (`Partyline.Protocol.OrderedMap`).
- Frames are msgpack `bin`, text is `str`; decoding keeps the two apart.
- Frame validation checks codec byte and duration only, as the reference
  does, so a Codec2 payload of a different mode but equal duration passes.

## Example

`examples/partyline_client.exs` browses `lxst.room` announces or joins a
server text-only and chats from stdin. Without `--hub` it uses the
interfaces in `~/.config/reticulum_ex.toml`.

```
# rns.moscow community server, through their own entry point
mix run examples/partyline_client.exs 1667b0e916759716ebb26e5d9d3a2c7e \
  --name mynick --hub rr.rns.moscow:4242

# listen for server announces for 60 minutes
mix run examples/partyline_client.exs --minutes 60
```

In a session: plain lines are chat, plus `/who`, `/rooms`,
`/join ROOM`, `/quit`.

## Development

Expects `../reticulum_ex` and `../bz2_ex` checked out next to this repo.

```
mix deps.get
mix test
```

## License

Dual-licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option. Unless you explicitly state otherwise, any contribution you
submit for inclusion shall be dual-licensed as above, without additional terms.
