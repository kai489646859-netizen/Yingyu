# Frequently asked questions

## Does Yingyu provide media or an Emby server?

No. You must provide a server, account and media that you are authorized to use.

## Should I uninstall before updating?

No. Use a cover installation unless a release note explicitly says otherwise. Uninstalling may remove local settings, accounts and caches.

## Why can original-quality playback still fail?

Original-file playback depends on the server response, authentication headers, redirects, byte-range support, source availability, network throughput and local decoder support. Yingyu does not silently guarantee that every server response can be played without conversion.

## Does HDR or Dolby text mean official Dolby output?

No. Identification or compatibility mapping is not Dolby certification and does not guarantee every profile, enhancement layer, passthrough mode or display result.

## Does ISO/BDMV support include full Blu-ray menus?

Not necessarily. Playlist/title reading is different from complete BD-J and interactive-menu support.

## Why may high-speed playback differ by device?

High-speed playback is limited by decode throughput, frame preparation, display scheduling, refresh rate and source cadence. A path verified on one device and media sample may behave differently elsewhere.

## Why do Android and Windows use different version numbers?

They are separate implementations with independent release histories. Use the platform name and tag, not only the numeric version, when reporting a problem.

## What should I include in an Issue?

Platform/version, device or PC configuration, OS, Emby version, source type, codec/container information, reproducible steps, time of failure and a manually redacted application log.
