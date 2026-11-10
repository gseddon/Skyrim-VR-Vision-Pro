# App icon source

`skyrim-icon.jpeg` (700x700): the silver Skyrim dragon emblem in a metal ring on black. Supplied by the user on 2026-11-10; the user
approved committing it to this repository. It is third-party artwork, kept here only as the source of the app icon; it is not part of the
app bundle (only `../Icon/` is).

`../Icon/Assets.xcassets/AppIcon.solidimagestack` (Back, Middle, Front, 1024x1024 PNG each) is generated from it by `make_icon.swift`:

    cd VXRuntime/xros/app && swift IconSource/make_icon.swift IconSource/skyrim-icon.jpeg Icon

* Front: the picture cropped to a square, scaled to 1024 with high-quality interpolation, black keyed out to transparency (alpha is the
  brightest channel, so Front over a black Back reproduces the picture).
* Middle: empty. Back: plain black. The system masks the stack to a circle.

`project.yml` lists `Icon` as a source and sets `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`; the fixture build (`make xros-app` with
`XROS_XRIZER_FIXTURE=1`) links it into its generated project.
