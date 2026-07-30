# ppp-multilink

A rebuild of OpenWrt's own `ppp` package with one extra patch, producing a
drop-in `ppp-multilink` that can actually form a Multilink PPP bundle.

Nothing here forks the package. The build clones OpenWrt at the release this
firmware is pinned to, takes `package/network/services/ppp` verbatim, drops
`patches/322-fix_ifunit_tdb_macro.patch` alongside OpenWrt's own patch stack and
bumps `PKG_RELEASE` so apk treats the result as an upgrade. Everything else --
sources, hashes, the other thirteen patches, the init scripts -- is whatever
OpenWrt ships.

## Why it exists

OpenWrt's `321-multilink_support_custom_iface_names.patch` requires a database
field, `IFUNIT=`, that its own writer stopped emitting when pppd 2.5.0 renamed
`USE_TDB` to `PPP_WITH_TDB`. Member links authenticate and then die with

	Couldn't create ppp interface <name>: File exists

on every OpenWrt carrying pppd 2.5.0 or later, including 25.12.5 (ppp 2.5.2-3).
The patch header has the full derivation.

This is an upstream OpenWrt bug and the fix belongs there. This package exists
so the bundle works before that lands.

## Installing

Pick the archive matching your router's package architecture -- not its CPU.
apk refuses a package whose arch string is not exactly the one the system was
built for, so `aarch64_generic` will not install on a `cortex-a53` device even
though the code would run.

	apk add --allow-untrusted ./ppp-multilink-2.5.2-r4.apk

`ppp-multilink` and `ppp` are mutually exclusive variants of the same source, so
this replaces whichever one is installed. A router that has plain `ppp` will
need the swap; one already running `ppp-multilink` sees a straight upgrade.

## Checking it took

	logread | grep "Link attached"

A bundle that formed logs `Link attached to <iface>` once per member link. Its
absence, with `Couldn't create ppp interface` in its place, means the running
pppd is still the stock one.
