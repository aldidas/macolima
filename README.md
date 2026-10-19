# Macolima

A minimalist, native SwiftUI Mac app to see and clean up containers, images and volumes on [Colima](https://github.com/abiosoft/colima): grouped containers, unused images and volumes, and the VM disk as Docker sees it next to what it really takes on your Mac.

> An unofficial, independent GUI for Colima. Not affiliated with or endorsed by the Colima project.

## Build from source

Requires macOS 26 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/aldidas/macolima
cd macolima
brew install xcodegen
make install
```

`make install` builds a Release copy (ad-hoc signed), installs it to `/Applications/Macolima.app` and launches it. Other targets: `make build`, `make run`, `make test`, `make clean`.

## License

MIT, see [LICENSE](LICENSE).
