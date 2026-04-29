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
SynthDef(\granular, { |out=0, buf=0, amp=1, pan=0.5, lag=0, n=60, rate=1.0,
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

// Kick Synth
// Three layers: tone (sine + pitch sweep), click (bandpass noise transient), noise (lpf noise tail).
// fstart: initial sweep frequency (Hz); pdec: pitch decay (ms).
// click: beater transient level; noise: noise body level; drive: tanh saturation on tone only.
// Percussive by default (s=0). Each synth creation fires its own Impulse for internal envelopes.
SynthDef(\kick, { |out=0, n=36, amp=0.8, pan=0.5, lag=0,
                   a=2, d=400, s=0.0, r=50, gate=1,
                   fstart=180, pdec=60,
                   click=0.5, noise=0.0, drive=0.0,
                   lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var fstartL   = VarLag.kr(fstart, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var clickL    = VarLag.kr(click, lagSec);
    var noiseL    = VarLag.kr(noise, lagSec);
    var driveL    = VarLag.kr(drive, lagSec);
    var atrig     = Impulse.ar(0);                                   // one-shot at synth creation
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Tone: sine with exponential pitch sweep from fstart down to freq
    var pitchEnv  = Decay2.ar(atrig, 0.001, pdecL / 1000);
    var sweepFreq = freq + (pitchEnv * (fstartL - freq));
    var driveGain = 1 + driveL * 9;                                  // 1x–10x
    var tone      = tanh(SinOsc.ar(sweepFreq) * driveGain) / tanh(driveGain);
    // Click: bandpass noise, ~8ms decay — the physical beater transient
    var clickSig  = BPF.ar(WhiteNoise.ar, 2500, 0.7) * Decay2.ar(atrig, 0.001, 0.008) * clickL;
    // Noise: lowpass body, decays at half the main envelope time
    var noiseSig  = LPF.ar(WhiteNoise.ar, 250) * Decay2.ar(atrig, 0.001, d / 2000) * noiseL;
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var sig       = Pan2.ar((tone + clickSig + noiseSig) * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Snare Synth
// Two layers: body (two inharmonic sines with pitch sweep) and snare noise (HPF white noise).
// body: tonal layer level; snap: wire noise level; tight: wire noise decay (ms).
// fstart/pdec: pitch sweep start (Hz) and decay (ms). drive: tanh saturation on body tones.
// Each layer has its own Decay2 envelope so body and wire decay independently.
SynthDef(\snare, { |out=0, n=48, amp=0.8, pan=0.5, lag=0,
                    a=2, d=150, s=0.0, r=30, gate=1,
                    fstart=250, pdec=30,
                    snap=0.8, body=0.7, drive=0.0, tight=120,
                    lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var fstartL   = VarLag.kr(fstart, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var snapL     = VarLag.kr(snap, lagSec);
    var bodyL     = VarLag.kr(body, lagSec);
    var driveL    = VarLag.kr(drive, lagSec);
    var tightL    = VarLag.kr(tight, lagSec);
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var atrig     = Impulse.ar(0);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Body: two inharmonic sines (drum head modes) with shared pitch sweep
    var pitchEnv  = Decay2.ar(atrig, 0.001, pdecL / 1000);
    var sweepFreq = freq + (pitchEnv * (fstartL - freq));
    var driveGain = 1 + driveL * 9;
    var tone1     = SinOsc.ar(sweepFreq);
    var tone2     = SinOsc.ar(sweepFreq * 1.6);
    var bodyEnv   = Decay2.ar(atrig, 0.001, d / 1000);
    var bodySig   = tanh((tone1 + (tone2 * 0.6)) * driveGain) / tanh(driveGain) * bodyEnv * bodyL;
    // Snare noise: HPF white noise for wire rattle, independently decaying
    var snareNoise = HPF.ar(WhiteNoise.ar, 1500) * Decay2.ar(atrig, 0.001, tightL / 1000) * snapL;
    var sig       = Pan2.ar((bodySig + snareNoise) * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Sub Synth
// presence: distorts a parallel copy and HPFs out the fundamental from it,
//   so only upper harmonics are added — the sine itself stays pure.
// lfoRate/lfoDepth: amplitude tremolo whose phase resets on each note trigger (starts at full amp).
// sweep: 2-octave pitch sweep on trigger — 1=falls from 2 octaves above, -1=rises from below, 0=off.
// sweepdec: sweep decay time (ms).
SynthDef(\sub, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                  a=1, d=0, s=1.0, r=50, gate=1,
                  presence=0.3, lforate=4.0, lfodepth=0.3,
                  sweep=0.0, sweepdec=200,
                  lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var presenceL = VarLag.kr(presence, lagSec);
    var lfoRateL  = VarLag.kr(lforate, lagSec);
    var lfoDepthL = VarLag.kr(lfodepth, lagSec);
    var sweepL    = VarLag.kr(sweep, lagSec);
    var sweepdecL = VarLag.kr(sweepdec, lagSec);
    var trig      = Trig1.kr(gate, 0.001);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    // Pitch sweep: 4^(sweep * decay) — 2 octaves up (sweep=1) or down (sweep=-1)
    var sweepEnv  = Decay2.kr(trig, 0.001, sweepdecL / 1000);
    var pitchFreq = freq * (4 ** (sweepL * sweepEnv));
    // Pure sine sub
    var sub       = SinOsc.ar(pitchFreq);
    // Presence: tanh-distort a copy, HPF to remove the fundamental, mix in at low level
    var distorted = tanh(sub * (presenceL * 8 + 1));
    var harmonics = HPF.ar(distorted, pitchFreq * 1.5) * presenceL;
    var sig       = sub + harmonics;
    // Amp LFO: phase resets to peak on each trigger so note always starts at full amplitude
    var lfoPhase  = Phasor.kr(trig, lfoRateL / ControlRate.ir, 0, 1, 0.25);
    var lfo       = sin(lfoPhase * 2pi);
    var ampMod    = 1 - (lfoDepthL * (1 - (lfo * 0.5 + 0.5)));
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    sig = Pan2.ar(sig * env * ampL * ampMod * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Subtractive Synth
// wave: 0=saw, 1=pulse; pw: pulse width (0-1, only used when wave=1)
// ffreq: base filter cutoff (Hz), fres: resonance (0=none, 1=max), fenv: Hz added to cutoff at envelope peak
// Filter tracks amp envelope shape. Post-process filters (lpf/hpf/bpf/res) work as on other synths.
SynthDef(\subtractive, { |out=0, n=60, wave=0, pw=0.5, amp=0.5, pan=0.5, lag=0,
                          a=10, d=200, s=0.5, r=300, gate=1,
                          ffreq=2000, fres=0.3, fenv=0,
                          lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec  = lag / 1000;
    var nL      = VarLag.kr(n, lagSec);
    var freq    = nL.midicps;
    var ampL    = VarLag.kr(amp, lagSec);
    var panL    = VarLag.kr(pan, lagSec);
    var pwL     = VarLag.kr(pw, lagSec);
    var ffreqL  = VarLag.kr(ffreq, lagSec);
    var fresL   = VarLag.kr(fres, lagSec);
    var fenvL   = VarLag.kr(fenv, lagSec);
    var env     = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var osc     = Select.ar(wave.round(1), [Saw.ar(freq), Pulse.ar(freq, pwL)]);
    var cutoff  = (ffreqL + (fenvL * env)).clip(20, 20000);
    var rq      = 1 - (fresL * 0.99);           // rq=1 no resonance, rq=0.01 max resonance
    var filtered = RLPF.ar(osc, cutoff, rq);
    var lpfL    = VarLag.kr(lpf, lagSec);
    var hpfL    = VarLag.kr(hpf, lagSec);
    var bpfL    = VarLag.kr(bpf, lagSec);
    var resL    = VarLag.kr(res, lagSec);
    var sig     = Pan2.ar(filtered * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Karplus-Strong plucked string
// Exciter is a noise burst triggered once at synth creation; pitch set by delay line (1/freq).
// decay: ring time (ms); coef: loop filter coefficient (0=bright, 1=dull/mellow)
// No d/s params — the physical decay is the envelope. Gate/release allow early cutoff.
SynthDef(\karplus, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                      decay=1000, coef=0.5,
                      a=1, r=50, gate=1,
                      lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec  = lag / 1000;
    var nL      = VarLag.kr(n, lagSec);
    var freq    = nL.midicps;
    var ampL    = VarLag.kr(amp, lagSec);
    var panL    = VarLag.kr(pan, lagSec);
    var decayL  = VarLag.kr(decay, lagSec);
    var coefL   = VarLag.kr(coef, lagSec);
    var env     = EnvGen.kr(Env.asr(a / 1000, 1.0, r / 1000), gate, doneAction: Done.freeSelf);
    var exciter = WhiteNoise.ar(1);
    var plucked = Pluck.ar(exciter, Impulse.kr(0), 0.05, freq.reciprocal, decayL / 1000, coefL);
    var lpfL    = VarLag.kr(lpf, lagSec);
    var hpfL    = VarLag.kr(hpf, lagSec);
    var bpfL    = VarLag.kr(bpf, lagSec);
    var resL    = VarLag.kr(res, lagSec);
    var sig     = Pan2.ar(plucked * env * ampL * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Pad — 7 detuned saws spread symmetrically across the stereo field (supersaw style)
// detune: total spread in cents across all voices; drift: per-voice slow random Hz offset
// Slow attack default (a=500). No d/s defaults encourage open sustain.
SynthDef(\pad, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                  detune=30, drift=0.5,
                  a=500, d=0, s=1.0, r=800, gate=1,
                  lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var detuneL   = VarLag.kr(detune, lagSec);
    var driftL    = VarLag.kr(drift, lagSec);
    var numVoices = 7;
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var voices    = numVoices.collect { |i|
        var pos         = i / (numVoices - 1) * 2 - 1;           // -1 to 1
        var detuneCents = pos * (detuneL / 2);                    // ±detune/2 cents each side
        var driftHz     = LFNoise1.kr(rrand(0.1, 0.5)) * driftL; // independent per-voice, rate fixed at build time
        var voiceFreq   = freq * (detuneCents / 100).midiratio + driftHz;
        Pan2.ar(Saw.ar(voiceFreq), pos)
    };
    var sig       = Mix(voices) / numVoices;
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    sig = Balance2.ar(sig[0], sig[1], panL * 2 - 1, ampL * env * 0.5);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Acid (TB-303 style)
// wave: 0=saw, 1=square. Filter auto-sweeps on every gate: opens to ffreq+fenv*(1+accent), decays over fdec ms.
// fenv: sweep amount in Hz — set to 0 for a static filter; accent: 0-1 boosts sweep and amp.
// Slide: use lag (ms) on n for portamento. Uses MoogFF ladder filter for authentic resonance.
SynthDef(\acid, { |out=0, n=60, wave=0, amp=0.5, pan=0.5, lag=0,
                   a=1, d=0, s=1.0, r=50, gate=1,
                   ffreq=300, fres=0.7, fenv=3000, fdec=300,
                   accent=0,
                   lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var ffreqL    = VarLag.kr(ffreq, lagSec);
    var fresL     = VarLag.kr(fres, lagSec);
    var fenvL     = VarLag.kr(fenv, lagSec);
    var fdecL     = VarLag.kr(fdec, lagSec);
    var accentL   = VarLag.kr(accent, lagSec);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var trig      = Trig1.kr(gate, 0.001);
    var filterEnv = Decay2.kr(trig, 0.001, fdecL / 1000);       // 0→1→0, decays over fdec ms
    var osc       = Select.ar(wave.round(1), [Saw.ar(freq), Pulse.ar(freq, 0.5)]);
    var cutoff    = (ffreqL + (fenvL * (1 + accentL) * filterEnv)).clip(20, 20000);
    var filtered  = MoogFF.ar(osc, cutoff, fresL * 4);           // gain 0-4; 4 = self-oscillation
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    var sig       = Pan2.ar(filtered * env * ampL * (1 + accentL) * 0.5, panL * 2 - 1);
    sig = Select.ar(lpfL > 0, [sig, LPF.ar(sig, lpfL.max(1))]);
    sig = Select.ar(hpfL > 0, [sig, HPF.ar(sig, hpfL.max(1))]);
    sig = Select.ar(bpfL > 0, [sig, BPF.ar(sig, bpfL.max(1), resL)]);
    Out.ar(out, sig);
}).add;

// Additive Lazer
// 8 sine partials at harmonic ratios. Pitch sweeps exponentially from freq*psweep down to freq over pdec ms.
// psweep: multiplier at note start (2.0=octave above, 1.0=no sweep); pdec: sweep decay (ms)
// rolloff: amplitude weight per partial as rolloff^i — 0.0=only fundamental, 1.0=all partials equal
// Percussive by default (s=0); sustain-capable if s raised. CPU cost: ~8 SinOscs, minimal.
SynthDef(\lazer, { |out=0, n=60, amp=0.5, pan=0.5, lag=0,
                        a=1, d=300, s=0.0, r=80, gate=1,
                        psweep=2.0, pdec=80,
                        rolloff=0.6,
                        lpf=0, hpf=0, bpf=0, res=1.0|
    var lagSec    = lag / 1000;
    var nL        = VarLag.kr(n, lagSec);
    var freq      = nL.midicps;
    var ampL      = VarLag.kr(amp, lagSec);
    var panL      = VarLag.kr(pan, lagSec);
    var psweepL   = VarLag.kr(psweep, lagSec);
    var pdecL     = VarLag.kr(pdec, lagSec);
    var rolloffL  = VarLag.kr(rolloff, lagSec);
    var env       = EnvGen.kr(Env.adsr(a / 1000, d / 1000, s, r / 1000), gate, doneAction: Done.freeSelf);
    var trig      = Trig1.kr(gate, 0.001);
    var pitchEnv  = Decay2.kr(trig, 0.001, pdecL / 1000);
    var sweepFreq = freq * (psweepL ** pitchEnv);    // exponential: psweep at attack, 1x at rest
    var sig       = Mix.fill(8, { |i|
        SinOsc.ar(sweepFreq * (i + 1)) * (rolloffL ** i)
    }) / 8;                                          // /8 normalises for rolloff=1 (all equal)
    var lpfL      = VarLag.kr(lpf, lagSec);
    var hpfL      = VarLag.kr(hpf, lagSec);
    var bpfL      = VarLag.kr(bpf, lagSec);
    var resL      = VarLag.kr(res, lagSec);
    sig = Pan2.ar(sig * env * ampL * 0.5, panL * 2 - 1);
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
