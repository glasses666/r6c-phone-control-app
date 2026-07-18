# lpac DJI runtime

This directory contains an arm64 macOS build of lpac 2.3.0 from upstream commit
`3ff35594ec15062a3ed10c3da1c26eb0a13390b8`.

The build enables the curl HTTP backend and the DJI USB APDU backend implemented
in `Tools/lpac-dji-usb.c`. The driver talks to the IG830/QDC507 AT interface over
libusb and supports both DJI's `2ca3:4006` identity and Quectel's `2c7c:0125`
identity. The app always selects it with `LPAC_APDU=dji_usb`.

Upstream: <https://github.com/estkme-group/lpac>

The copied upstream license texts are in `LICENSES/`.
