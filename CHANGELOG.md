# Changelog

## [0.3.0](https://github.com/gamunu/smudge/compare/v0.2.0...v0.3.0) (2026-11-02)


### Features

* **app:** show scanner state and add scanner sharing setting ([0c1ced6](https://github.com/gamunu/smudge/commit/0c1ced625eb08dd72fd42f44d65e2d388518d988))
* **firmware:** load HP firmware into LaserJets at power-on ([6d9f865](https://github.com/gamunu/smudge/commit/6d9f86578ea73e64c4c69418fd09a8456004dff1))
* **jpeg:** port the JetReady Mojave color table, enable JetReady and QuickConnect ([4312a5d](https://github.com/gamunu/smudge/commit/4312a5d56a997f3a2d62d3adcd0366594f453ec8))
* **ppd:** keep models whose plugin need is scan or speed only ([03cbebb](https://github.com/gamunu/smudge/commit/03cbebb0ef7fd30a00384bacea55cbc787926edb))
* print on the HP printers that needed HP's plugin ([80aaf99](https://github.com/gamunu/smudge/commit/80aaf9980b8e58e226a7ebdf7b35eeb2198149fd))
* **scan:** add ledm scan session and hardware probe ([217c98b](https://github.com/gamunu/smudge/commit/217c98b1e8cf6ee5fd62eecf4d2591d40bf7a4b4))
* **scan:** parse ledm scan caps and build ledm scan jobs ([a5f44aa](https://github.com/gamunu/smudge/commit/a5f44aa8c5778e2ed28baf9ba2abc45c4bdb39db))
* **scan:** plan ledm jobs from escl settings and render pages ([7e7595d](https://github.com/gamunu/smudge/commit/7e7595d5a97d195506a748fd30fc5378d5aaf4e1))
* **scan:** route escl requests to ledm scan jobs ([527716a](https://github.com/gamunu/smudge/commit/527716adf241acee92793936b9783a7240576126))
* **scan:** scan from image capture and preview over usb ([34b0194](https://github.com/gamunu/smudge/commit/34b0194907fee0cd913357ace4c29c208089c88a))
* **scan:** serve escl on loopback and advertise it local-only ([3570e76](https://github.com/gamunu/smudge/commit/3570e76fc42a7578f30d9e54f28b0511d5189618))
* **scan:** stream jpeg scans as an uncompressed tiff of known size ([272fd42](https://github.com/gamunu/smudge/commit/272fd4201a10aa95cc33fdf5aa9302bb1c57a5e1))
* **scan:** translate ledm caps to escl and parse escl scan settings ([4f4b062](https://github.com/gamunu/smudge/commit/4f4b062da822c85104da75bd9d5279829190b6c7))
* **scan:** watch usb scanners and serve them for the console user ([ddd09ce](https://github.com/gamunu/smudge/commit/ddd09ce7235805d15b2fc644c2caf540f5cec9b7))
* **zjs:** compress ZjStream and ZxStream pages without HP's plugin ([fb98df2](https://github.com/gamunu/smudge/commit/fb98df2ff28debbc972c0bcf9996b554c615d153))


### Bug fixes

* **app:** do not show a scan as printer work in the job card ([feb0eaf](https://github.com/gamunu/smudge/commit/feb0eafaa32e384a210d258443f257a256de6664))
* harden the print filter and scanner agent against hostile input ([661164a](https://github.com/gamunu/smudge/commit/661164a1f8933d801855630e2efc45b3344209c6))
* **hpcups:** bound the hbpl1 colour theme and init compressBuf ([9aff932](https://github.com/gamunu/smudge/commit/9aff932cb86ef5b44e33e3e454d0d3b45b9949e5))
* **hpcups:** compute buffer sizes wide and bound the page height ([c718c19](https://github.com/gamunu/smudge/commit/c718c190fc6fbc337be9cbfd3e0bd81d42884a91))
* **hpcups:** compute buffer sizes wide and bound the page height ([7e63b17](https://github.com/gamunu/smudge/commit/7e63b17dcb25435dbc84de0a4e00683c9f3d5ac9))
* **hpcups:** count mode 3 runs in an unsigned int ([4204927](https://github.com/gamunu/smudge/commit/4204927bbb89c379ae36fdd6f493daaf8ca95d83))
* **hpcups:** keep the imaging box inside the page ([261d68a](https://github.com/gamunu/smudge/commit/261d68a97a4b2bf6a3b7e621ff40a8bfd6ff57a3))
* **hpcups:** validate raster headers and fix memory errors ([f1a3ba1](https://github.com/gamunu/smudge/commit/f1a3ba1e6b542972c65e0a92a2b8f997ba27fefa))
* **scand:** refuse eSCL requests that come from a web page ([21d256c](https://github.com/gamunu/smudge/commit/21d256c38b4b8458185c3f1c304c0e6b45c39dff))
* **scan:** keep polling a job until its page is ready ([e2286cb](https://github.com/gamunu/smudge/commit/e2286cb824167cd43e5c048a259a59af118387c9))
* **scan:** let the deskjet 2300 apply brightness and contrast ([2bcb11b](https://github.com/gamunu/smudge/commit/2bcb11b6189bcdd833b76052933b87b2897ad65c))
* **scan:** notice a printer unplugged during a scan ([409cb27](https://github.com/gamunu/smudge/commit/409cb276df1c3accd5f72a62c55ee4be0ae7a0a7))
* **scan:** release usb read buffers on every pass of a page download ([d969223](https://github.com/gamunu/smudge/commit/d9692233624b2ba6f8f814136bcacec7d97d637c))
* **scan:** stop streams from reading pages of earlier runs ([d18b855](https://github.com/gamunu/smudge/commit/d18b855f59285770ac1efe51c8dc860ded95b6bb))
* **scan:** stream jpeg pages and retry processed ones ([1cb9be9](https://github.com/gamunu/smudge/commit/1cb9be9c185aad373477f08f530c1d9c290028d6))
* **scan:** watch usb arrivals and removals that actually fire ([825bc5d](https://github.com/gamunu/smudge/commit/825bc5dbdc648394c2503278cef6d561aa864f87))


### Documentation

* describe scanning through image capture ([bcfdf63](https://github.com/gamunu/smudge/commit/bcfdf63f2e8f05319e33752c779c765e4ec04b14))
* **scan:** design and plan for scanning through image capture ([20d153a](https://github.com/gamunu/smudge/commit/20d153a78f16c06ba8db78c109c34238fc659473))
* **scan:** record end to end scans through imagecapturecore ([e4e0391](https://github.com/gamunu/smudge/commit/e4e03919e1c1e31cb68bd442b69732e61d80ad18))
* **scan:** record ledm scan behaviour measured on the 2336 ([ba9d04f](https://github.com/gamunu/smudge/commit/ba9d04f7a5f2e58bae461f58043031fc4b3b97c4))
* **scan:** record progress and memory after the tiff stream ([9b4f6ac](https://github.com/gamunu/smudge/commit/9b4f6ac7a53a51064f5b218c5f38ea874d47cc67))
* **scan:** record that printing during a scan works on the 2336 ([9aef78e](https://github.com/gamunu/smudge/commit/9aef78e8dc276ab28fa1aabf5e32800e36089e16))
* **scan:** record tiff stream checks and the jpeg file limitation ([fd4156d](https://github.com/gamunu/smudge/commit/fd4156d302a2335a284f1c28dc13004c7d58c04c))
* **scan:** record unplug and replug behaviour on the 2336 ([9805333](https://github.com/gamunu/smudge/commit/9805333e4eeb431421e29422c5911a29da3a287e))
* **scan:** stream uncompressed tiff so image capture shows progress ([9ed79da](https://github.com/gamunu/smudge/commit/9ed79da82887916f54b450198b97d1b3c2e4ca29))

## [0.2.0](https://github.com/gamunu/smudge/compare/v0.1.0...v0.2.0) (2026-10-29)


### ⚠ BREAKING CHANGES

* the old app, filter path, PPDs and receipt are not removed. Uninstall hpcups-macos first and add the printer queue again with the ", Smudge" driver.

### Features

* install from terminal without the gatekeeper prompt ([0bee356](https://github.com/gamunu/smudge/commit/0bee35619b57bf7d2e51675bc232b0c99fc5ac2f))
* rename the project and app to smudge ([26c824d](https://github.com/gamunu/smudge/commit/26c824d7cace95b36c2725f8ec437bcf7e4629da))


### Documentation

* **readme:** add the homebrew install ([baefbb6](https://github.com/gamunu/smudge/commit/baefbb6687861870c094942f747b915770397110))

## 0.1.0 (2026-10-29)

First release.

- Native Apple Silicon build of HPLIP's hpcups driver, with PPDs for 778 HP printers that work without HP's plugin.
- hpcups Status: printer state, jobs, ink levels, and guided cleaning, diagnostics and head alignment with pictures for every step.
- One installer for the driver and the app, and automatic updates with Sparkle.

Tested on hardware: HP DeskJet 2300 over USB.
