/** 
Custom SynthDefs can be added here.

Each SynthDef should have the following parameters:
- out: the output bus (default 0, the main audio output)
- a, d, s, r: ADSR envelope parameters in ms (default 10, 100, 0.7, 300)
- n: MIDI note number (default 60, middle C)
- pan: stereo pan from 0 (left) to 1 (right) (default 0.5)
- lag: time in ms for parameter changes to take effect (default 0)
    - optionally wrap parameter changes in VarLag.kr to apply the lag
- gate: 1 when the note is on, 0 when it's off (default 1)

Example usage (simple):
SynthDef(\mySynth, { |out=0, n=60, a=10, d=100, s=0.7, r=300, pan=0.5, lag=0, gate=1|
    var freq = n.midicps;
    var env  = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    Out.ar(out, Pan2.ar(SinOsc.ar(freq) * env * 0.5, pan * 2 - 1));
}).add;

Example usage (with lag):
SynthDef(\myLagSynth, { |out=0, n=60, a=10, d=100, s=0.7, r=300, pan=0.5, lag=100, gate=1|
    var lagSec = lag / 1000;
    var freq   = VarLag.kr(n, lagSec).midicps;
    var env    = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    Out.ar(out, Pan2.ar(SinOsc.ar(freq) * env * 0.5, pan * 2 - 1));
}).add;
*/