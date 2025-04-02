# LKTestHost

Minimal application for running unit tests on device.

## Environment

| Key                          | Default               |
| ---------------------------- | --------------------- |
| `LIVEKIT_TESTING_URL`        | `ws://localhost:7880` |
| `LIVEKIT_TESTING_API_KEY`    | `devkey`              |
| `LIVEKIT_TESTING_API_SECRET` | `secret`              |

Set these values by specifying them under the arguments tab for the "LKTestHost" scheme.

Some tests require access to a LiveKit server. For testing on-device, you can run a development server on your Mac and set `LIVEKIT_TESTING_URL` accordingly:

```sh
livekit-server --dev --bind 0.0.0.0
# Set `LIVEKIT_TESTING_URL` to `ws://<lan ip>:7880`
```

Make sure to allow local network access when prompted.

## Usage

1. Open the Xcode Project
2. Select your device
3. Click the icon for "Build and then test current scheme"