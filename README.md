# SideWatch

SideWatch is an experimental SideStore fork that models, provisions, rewrites,
and signs the complete nested bundle hierarchy of an IPA, including Apple Watch
companion applications and WatchKit extensions.

> **Artifact warning:** the macOS CI workflow intentionally builds with Xcode
> code signing disabled and applies only ldid development/fake signatures. Its
> `SideWatch-Unsigned.ipa` artifact is input for a legitimate installer such as
> AltServer to re-sign with a certificate and device provisioning profiles. It
> is not a directly installable IPA. Direct installation of that raw artifact
> must fail Apple application verification because it has no embedded device
> profiles and no valid enclosing resource seals.

Watch signing additionally requires the paired Apple Watch to be registered on
the same Apple developer team. SideWatch now stops with a specific diagnostic
when no registered Watch exists or the generated watchOS profile omits it.

See [the signing architecture](docs/SIDEWATCH_SIGNING_ARCHITECTURE.md) for the
bundle graph, validation rules, build classifications, and current verification
boundary.

> SideStore is an *untethered, community driven* alternative app store for non-jailbroken iOS devices 

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://makeapullrequest.com)
[![Nightly SideStore build](https://github.com/SideStore/SideStore/actions/workflows/nightly.yml/badge.svg)](https://github.com/SideStore/SideStore/actions/workflows/nightly.yml)
[![.github/workflows/beta.yml](https://github.com/SideStore/SideStore/actions/workflows/beta.yml/badge.svg)](https://github.com/SideStore/SideStore/actions/workflows/beta.yml)
[![Discord](https://img.shields.io/discord/949183273383395328?label=Discord)](https://dis.sidestore.io)

![Alt](https://repobeats.axiom.co/api/embed/3a329ce95955690b9a9366f8d5598626a847d96c.svg "Repobeats analytics image")

SideStore is an iOS application that allows you to sideload apps onto your iOS device with just your Apple ID. SideStore resigns apps with your personal development certificate, and then uses a [specially designed VPN](https://github.com/jkcoxson/em_proxy) in order to trick iOS into installing them. SideStore will periodically "refresh" your apps in the background, to keep their normal 7-day development period from expiring.

SideStore's goal is to provide an untethered sideloading experience. It's a community driven fork of [AltStore](https://github.com/rileytestut/AltStore), and has already implemented some of the community's most-requested features.

(Contributions are welcome! 🙂)

## Requirements
- Xcode 26.4 for the current branch
- iOS 15+
- Rustup (`brew install rustup`)

Why iOS 15? Targeting a newer iOS release allows the project to use the SwiftUI
and concurrency APIs on which the current SideStore pipeline depends.
## Project Overview

### SideStore
SideStore is a just regular, sandboxed iOS application. The AltStore app target contains the vast majority of SideStore's functionality, including all the logic for downloading and updating apps through SideStore. SideStore makes heavy use of standard iOS frameworks and technologies most iOS developers are familiar with.

### EM Proxy
[EM Proxy](https://github.com/jkcoxson/em_proxy) powers the defining feature of SideStore: untethered app installation. By leveraging a custom-built App Store app with additional entitlements ([LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN)) to create the VPN tunnel for us, it allows SideStore to take advantage of [Jitterbug](https://github.com/osy/Jitterbug)'s loopback method without requiring a paid developer account.

### Minimuxer
[Minimuxer](https://github.com/jkcoxson/minimuxer) is a lockdown muxer that can run inside iOS’s sandbox. It replicates Apple’s usbmuxd protocol on macOS to “discover” devices to interface with LocalDevVPN on-device.

### Roxas
[Roxas](https://github.com/rileytestut/roxas) is Riley Testut's internal framework from AltStore used across many of their iOS projects, developed to simplify a variety of common tasks used in iOS development.

We're hoping to eventually eliminate our dependency on it, as it increases the amount of unnecessary Objective-C in the project.

## Contributing/Compilation Instructions

Please see [CONTRIBUTING.md](./CONTRIBUTING.md)

## Licensing

This project is licensed under the **AGPLv3 license**.
