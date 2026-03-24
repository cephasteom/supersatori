# SuperSatori
An alternative synthesis engine for [Satori](https://satori.cephasteom.co.uk).

## Installationn
* `npm i` to install node modules
* Download Supercollider from [https://supercollider.github.io/](https://supercollider.github.io/)
* `npm run start`

The location of your Supercollider install is determined in `scripts/sclang.js`. If you're getting errors along the lines of `[synth] sh: sclang: command not found`, you need to update this file so SuperSatori can find sclang.

## Using in Satori
* Reload Satori, adding \`?engine=supersatori\` to the URL. e.g. [https://satori.cephasteom.co.uk?engine=supersatori]
* Use as normal, but `inst` parameter becomes name of the synthdef

## Synthdefs
See `synth/synthdefs.scd` for available instruments. To add your own, edit `synth/custom-synthdefs.scd`.