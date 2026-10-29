Full production snapshots immediately before the 0.8.3 signed HTTP transport fix.
Only relative imports were localized to package:yingyu imports for the replay.
No class body or behavior was edited in these snapshots.

Original origin_transport.dart SHA256:
84B84E7075F3E0360253409E8894B57D8186D6B28C8ACF41676703E66DE1721E
Original disc_transport.dart SHA256:
A0AAC17FE332A697FF60D34F6602BB85D23433728B06E6A222671E6E5FEC3F7F

The same loopback fixtures run against old and current full transports.
These are synthetic HTTP protocol checks, not Android/MPV/media-device playback.
They do not prove that the two upstream header timeouts in the attached 0.8.2
log were caused by signature normalization or fixed on the user's server.
