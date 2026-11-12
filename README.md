# bf2-voip-sender

Talks into a Battlefield 2 server's voice relay the same way a real squad member does.
x86-64 assembly, Linux, no libc, and its own Speex encoder, because apparently we hate ourselves.

Why? Because we can't find the real alger :D

For the people who know:  We love you our dearest lagoon!

## build

```
make
```

You need `nasm` and `ld`. That's it.

## run example

```
./alger --relay 10.0.0.12:55125 --session 4242 --channel squad --wav lagoon.wav
```

or live from a mic on another box:

```
ffmpeg -f pulse -i default -f s16le -ar 8000 -ac 1 - | ssh vps ./alger --relay 10.0.0.12:55125 --session 4242 --stdin
```

| flag | what |
|---|---|
| `--relay host:port` | the server's voice relay. dotted IPv4, default port 55125 |
| `--session N` | your voice session id |
| `--channel squad\|leader` | squad chat, or the leader channel |
| `--wav file` | 16-bit PCM or 32-bit float wav, mono or stereo, any sample rate |
| `--stdin` | raw 16-bit little endian mono at 8 kHz |

## where do I get a session id

From a client that is actually connected to the server. The game hands every player one when
they join. How you get yours is your problem, alger does not do the joining.

## wire format

What the relay wants, one UDP datagram every 0.28 s:

```
[14 speex frames, 20 bytes each][frame counter, u16 LE][session id, u16 LE][type]
```

- frames are Speex narrowband, 8 kbps (the voipQuality 3 setting, BF2's default). it's baked in,
  there's no flag for it
- the counter is where the packet's first frame sits in the stream, so it goes up by 14 every
  packet. keep it running during silence. if it stands still the other side drops packets and
  you sound like a bad 56k modem
- type 1 is squad, type 2 with a channel byte in front of the session id is the leader line
- type 6 with no audio is a keepalive, alger sends one every 3 s

Other voipQuality settings use other frame sizes. alger is a simple man and only speaks q3.

## the encoder

Written from scratch in asm against the Speex decoder, so whatever the game decodes is what
alger meant. Uses the Speex codebooks.