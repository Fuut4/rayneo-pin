# Contributing to RayNeoPin

Thanks for helping! Bug reports, hardware reports, and pull requests are all welcome. You don't need to ask before opening a PR.

## Reporting issues

Please include:

- Your glasses model and firmware, if you know it.
- Your Mac model and macOS version.
- What happened, and what you expected.
- The output of `./RayNeoPin.app/Contents/MacOS/RayNeoPin --imu-test` for a few seconds, if tracking looks wrong.
- The output of `swiftc -O tools/probe.swift -o probe && ./probe 3 --enable`, if the IMU doesn't respond at all.

**Reports from other RayNeo models are especially useful.** Even a report that only says "works on Air 3s" or "no IMU data on Air 2" helps.

## Pull requests

- Keep the project dependency-free. It builds with nothing but `swiftc` (see `build.sh`).
- Match the existing style: small and readable, with comments only where the *why* isn't obvious.
- Test on real glasses when your change touches tracking or rendering, and say in the PR which model you used.
- One topic per PR.

Good first areas are listed under *Known limitations* in the [README](README.md).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
