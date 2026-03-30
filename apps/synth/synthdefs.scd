// Reverb — reads from and replaces the group's private bus
SynthDef(\satoriReverb, { |in=0, wet=0.5, room=0.8, damp=1.0, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var roomL  = VarLag.kr(room, lagSec);
    var dampL  = VarLag.kr(damp, lagSec);
    var sig    = In.ar(in, 2);
    ReplaceOut.ar(in, FreeVerb2.ar(sig[0], sig[1], wetL, roomL, dampL));
}).add;

// Delay — time and decay in ms
SynthDef(\satoriDelay, { |in=0, wet=0.5, time=300, decay=1000, lag=0|
    var lagSec  = lag / 1000;
    var wetL    = VarLag.kr(wet, lagSec);
    var timeL   = VarLag.kr(time, lagSec);
    var decayL  = VarLag.kr(decay, lagSec);
    var sig     = In.ar(in, 2);
    var delayed = CombC.ar(sig, 2.0, timeL / 1000, decayL / 1000);
    ReplaceOut.ar(in, XFade2.ar(sig, delayed, wetL * 2 - 1));
}).add;

// Chorus — rate in Hz, depth in ms
SynthDef(\satoriChorus, { |in=0, wet=0.5, rate=0.5, depth=5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var rateL  = VarLag.kr(rate, lagSec);
    var depthL = VarLag.kr(depth, lagSec);
    var sig    = In.ar(in, 2);
    var lfo    = SinOsc.kr(rateL, [0, 0.5pi]) * (depthL / 1000) + 0.02;
    var chorus = DelayC.ar(sig, 0.1, lfo);
    ReplaceOut.ar(in, XFade2.ar(sig, chorus, wetL * 2 - 1));
}).add;

// Bitcrusher — bits: bit depth (1-16), rate: sample rate as fraction of full rate (0-1)
SynthDef(\satoriBitcrusher, { |in=0, wet=0.5, bits=5, rate=0.5, lag=0|
    var lagSec  = lag / 1000;
    var wetL    = VarLag.kr(wet, lagSec);
    var bitsL   = VarLag.kr(bits, lagSec).round(1).max(1);
    var rateL   = VarLag.kr(rate, lagSec).clip(0.001, 1.0);
    var sig     = In.ar(in, 2);
    var crushed = Latch.ar(sig, Impulse.ar(SampleRate.ir * rateL));
    var step    = 2 ** (1 - bitsL);
    crushed     = (crushed / step).round * step;
    ReplaceOut.ar(in, XFade2.ar(sig, crushed, wetL * 2 - 1));
}).add;

// Overdrive — drive: 0-1, maps exponentially to internal gain 1-50
// Uses tanh for smooth soft clipping; output is normalised so unity gain at any drive level
SynthDef(\satoriOverdrive, { |in=0, wet=0.5, drive=0.5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var driveL = VarLag.kr(drive, lagSec).linexp(0, 1, 1, 50);
    var sig    = In.ar(in, 2);
    var driven = tanh(sig * driveL) / tanh(driveL);
    ReplaceOut.ar(in, XFade2.ar(sig, driven, wetL * 2 - 1));
}).add;

// Wavefolder — gain: 0-1, maps exponentially to internal gain 1-8
SynthDef(\satoriFolder, { |in=0, wet=0.5, gain=0.5, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    var gainL  = VarLag.kr(gain, lagSec).linexp(0, 1, 1, 8);
    var sig    = In.ar(in, 2);
    var folded = (sig * gainL).fold2(1);
    ReplaceOut.ar(in, XFade2.ar(sig, folded, wetL * 2 - 1));
}).add;

// Per-stream limiter — sits at the tail of each group's private bus
SynthDef(\satoriLimiter, { |in=0, out=0, level=0.9|
    Out.ar(out, Limiter.ar(In.ar(in, 2), level));
}).add;

// FX send — reads from a source stream bus and additively writes to an fx stream bus
SynthDef(\satoriSend, { |in=0, out=0, wet=0, lag=0|
    var lagSec = lag / 1000;
    var wetL   = VarLag.kr(wet, lagSec);
    Out.ar(out, In.ar(in, 2) * wetL);
}).add;

// Sampler — buffers are normalised to stereo at load time (mono files get ch0 duplicated)
// Rate chain: snap (cycles to fill) sets base rate, n (midi, 60=1x) scales pitch, rate is final multiplier
// Negative rate plays backwards. Without snap, just n * rate.
SynthDef(\sampler, { |out=0, buf=0, amp=0.5, pan=0.5, lag=0, n=60, rate=1.0, begin=0, loop=0,
                      snap=0, cps=1, a=1, d=0, s=1.0, r=50, gate=1,
                      lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var nL        = VarLag.kr(n, lagSec);
    var rateL     = VarLag.kr(rate, lagSec);
    var nScale    = (nL - 60).midiratio;
    var snapRate  = BufDur.kr(buf) * cps / snap.max(1e-4);
    var baseRate  = Select.kr(snap > 0, [1, snapRate]);
    var finalRate = baseRate * nScale * rateL * BufRateScale.kr(buf);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var sig       = PlayBuf.ar(2, buf, finalRate,
                      startPos: begin * BufFrames.kr(buf), loop: loop);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Granular Synth — uses Warp1 which reads stereo buffers directly (no duplicate mono buffers needed)
// begin: start position for the scan (0-1)
// snap: cycles to traverse the full buffer (0 = static position at begin)
// rate: multiplies scan speed
// n: pitch within grains (midi, 60 = original pitch), independent of scan speed
// posrand: per-grain position scatter (0-1), overlaps: simultaneous grains
// gdur: grain duration (ms)
SynthDef(\granular, { |out=0, buf=0, amp=0.5, pan=0.5, lag=0, n=60, rate=1.0,
                       snap=0, cps=1,
                       begin=0, posrand=0.0,
                       gdur=100, overlaps=8,
                       a=10, d=100, s=1.0, r=300, gate=1,
                       lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec      = lag / 1000;
    var ampL        = VarLag.kr(amp, lagSec);
    var panL        = VarLag.kr(pan, lagSec);
    var nL          = VarLag.kr(n, lagSec);
    var rateL       = VarLag.kr(rate, lagSec);
    var beginL      = VarLag.kr(begin, lagSec);
    var nScale      = (nL - 60).midiratio;
    // Phasor scans from begin to 1.0 in snap cycles, rate multiplies speed
    var pointerRate = cps * rateL / snap.max(1e-4) / ControlRate.ir;
    var movingPtr   = Phasor.kr(0, pointerRate, beginL, 1.0, beginL);
    var pointer     = Select.kr(snap > 0, [beginL, movingPtr]);
    var gdurSec     = gdur / 1000;
    var sig         = Warp1.ar(2, buf, pointer, nScale, gdurSec, -1, overlaps, posrand, 2);
    var env         = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// FM Synth
// Params: note (midi), harm, modi, amp, pan, lag (ms), ADSR envelope (a, d, s, r, gate)
// Modulator envelope (moda, modd, mods, modr) scales the mod index over time
// Keyscaling: both mod index and amp scale by 2^(-0.5) per octave above middle C
SynthDef(\fm, { |out=0, n=60, harm=2.0, modi=3.0, amp=0.5, pan=0.5, lag=0,
                 a=10, d=100, s=0.7, r=300, gate=1,
                 moda=0, modd=100, mods=1.0, modr=500,
                 lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec   = lag / 1000;
    var nL       = VarLag.kr(n, lagSec);
    var freq     = nL.midicps;
    var ks       = (nL - 60) / 12;            // octaves above/below middle C
    var modIdx   = VarLag.kr(modi, lagSec) * (2 ** (ks * -0.5));
    var ampL     = VarLag.kr(amp, lagSec) * (2 ** (ks * -0.5));
    var panL     = VarLag.kr(pan, lagSec);
    var modEnv   = EnvGen.kr(Env.adsr(moda / 1000, modd / 1000, mods, modr / 1000), gate);
    var mod      = SinOsc.ar(freq * harm, 0, freq * modIdx * modEnv);
    var car      = SinOsc.ar(freq + mod);
    var env      = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var lpfL  = VarLag.kr(lpf, lagSec);
    var hpfL  = VarLag.kr(hpf, lagSec);
    var bpfL  = VarLag.kr(bpf, lagSec);
    var resL  = VarLag.kr(res, lagSec);
    var sig   = Pan2.ar(car * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;
