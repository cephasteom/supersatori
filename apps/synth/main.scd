// Load config before boot so device and output channel settings apply to s.options
(thisProcess.nowExecutingPath.dirname +/+ "config.scd").load;
if(~device.notNil) { s.options.device = ~device };
s.options.numOutputBusChannels = ~numOutputs ?? 2;

s.waitForBoot {
    var customPath = thisProcess.nowExecutingPath.dirname +/+ "custom-synthdefs.scd";
    var priorKeys  = SynthDescLib.global.synthDescs.keys.as(Set);

    // load core synthdefs
    load(thisProcess.nowExecutingPath.dirname +/+ "synthdefs.scd");

    // load user-defined SynthDefs if present
    if(File.exists(customPath)) { load(customPath) };

    // Collect newly added instrument synthdefs (excludes satori* fx/utility defs),
    // build a JSON payload and send to bridge on port 57200.
    // ADSR args are collapsed into a single "adsr" array; gate/out/in are omitted.
    {
        var skipArgs = #[\out, \in, \gate];
        var adsrArgs = #[\a, \d, \s, \r];
        var newKeys  = SynthDescLib.global.synthDescs.keys.as(Set) - priorKeys;
        var instrs   = newKeys.reject { |k| k.asString.beginsWith("satori") }.asArray.sort;
        var fmtVal   = { |v|
            var r = v.round(0.0001);
            if(r == r.trunc) { r.asInteger.asString } { r.asString }
        };
        var entries  = instrs.collect { |name|
            var desc    = SynthDescLib.global.at(name);
            var args    = [];
            var adsr    = [0.0, 0.0, 1.0, 50.0];
            var hasADSR = false;
            desc.controls.do { |ctrl|
                var n = ctrl.name.asSymbol;
                if(skipArgs.includes(n).not) {
                    if(adsrArgs.includes(n)) {
                        adsr[adsrArgs.indexOf(n)] = ctrl.defaultValue;
                        hasADSR = true;
                    } {
                        args = args.add("\"" ++ n ++ "\":" ++ fmtVal.(ctrl.defaultValue));
                    }
                }
            };
            if(hasADSR) {
                args = args.add("\"adsr\":[" ++ adsr.collect { |dv| fmtVal.(dv) }.join(",") ++ "]");
            };
            "\"" ++ name ++ "\":{" ++ args.join(",") ++ "}"
        };
        ~synthdefsJSON = "{\"type\":\"synthdefs\",\"synthdefs\":{" ++ entries.join(",") ++ "}}";
        File.open(thisProcess.nowExecutingPath.dirname +/+ "synthdefs.json", "w")
            .write(~synthdefsJSON)
            .close;
        "Satori: wrote % instrument synthdef(s) to synthdefs.json".format(instrs.size).postln;
    }.();

    // Parse OSC args into a dictionary, e.g. ["/satori/s0/event", "inst", "fm", "n", 60] -> {inst: "fm", n: 60}
    ~parseParams = { |args|
        var dict = Dictionary.new;
        args.clump(2).do { |pair| dict[pair[0].asSymbol] = pair[1] };
        dict
    };

    // Independent TempoClock driven by incoming cps.
    // 1-second lookahead keeps the SC clock well behind the frontend so events
    // always arrive early enough to schedule cleanly, absorbing WebSocket jitter.
    ~satoriClock = nil;
    ~clockCps    = nil;

    ~lookahead = 0.1; // seconds

    ~syncClock = { |cps, cycleTime|
        var needsResync = false;
        if(~satoriClock.isNil) {
            needsResync = true;
        } {
            var expectedCycleTime = ~satoriClock.beats;
            // Detect restart: cycleTime jumped backwards
            if(cycleTime < (expectedCycleTime - 1)) { needsResync = true };
            if(cps != ~clockCps) { needsResync = true };
        };
        if(needsResync) {
            if(~satoriClock.notNil) { ~satoriClock.stop };
            ~satoriClock = TempoClock.new(cps, cycleTime, thisThread.seconds + ~lookahead);
            ~clockCps = cps;
        }
    };

    // each stream gets its own group, private bus, and voice dictionary
    ~groups     = Dictionary.new;
    ~buses      = Dictionary.new; // stream -> private audio Bus
    ~limiters   = Dictionary.new; // stream -> limiter Synth (anchor for effect insertion)
    ~effects    = Dictionary.new; // stream -> Dictionary(effectName -> Synth)
    ~voices         = Dictionary.new; // stream -> Dictionary(note -> Synth)
    ~voiceOrder     = Dictionary.new; // stream -> List of notes (oldest first)
    ~voiceTokens    = Dictionary.new; // stream -> Dictionary(note -> Integer), strum-guard tokens
    ~midiVoices     = Dictionary.new; // stream -> Dictionary(note -> midiVoice)
    ~midiVoiceOrder = Dictionary.new; // stream -> List of notes (oldest first)
    ~fxSends    = Dictionary.new; // sourceStream -> Dictionary(fxStreamName -> sendSynth)

    // Container group that always runs after all source stream groups; fx groups live inside it
    ~fxContainer = Group.new(s, \addToTail);

    // 4 shared sidechain buses (bus0–bus3): any stream can send to these for use as gate detectors
    ~sidechainBuses = Array.fill(4, { Bus.audio(s, 2) });
    ~sidechainSends = Dictionary.new; // stream -> Dictionary(busIndex -> sendSynth)

    // Sample banks: bankName -> Array of Buffers (sorted by filename)
    ~banks = Dictionary.new;

    ~loadSamples = {
        var audioExts = #["wav", "aif", "aiff", "flac", "mp3"];
        (~sampleDirs ?? []).do { |dir|
                var expanded = dir.standardizePath;
                if(File.exists(expanded)) {
                    PathName(expanded).folders.do { |folder|
                        var bankName = folder.folderName.asSymbol;
                        var maxN  = ~maxBuffersPerBank ?? 64;
                        var files = folder.files
                            .select { |f| audioExts.includesEqual(f.extension.toLower) }
                            .sort   { |a, b| a.fileName < b.fileName }
                            .keep(maxN);
                        if(files.size > 0) {
                            // Detect channel count for each file and load buffers
                            var chansList = files.collect { |f|
                                var sf = SoundFile.new;
                                var ch = if(sf.openRead(f.fullPath) && (sf.numChannels == 1)) {
                                    sf.close; [0, 0]
                                } { sf.close; [0, 1] };
                                ch
                            };
                            ~banks[bankName] = files.collect { |f, i|
                                Buffer.readChannel(s, f.fullPath, channels: chansList[i]);
                            };
                            "Satori: loaded bank '%' (% samples)".format(bankName, files.size).postln;
                        }
                    }
                } {
                    "Satori: sample dir not found: %".format(dir).postln;
                }
            }
    };

    ~loadSamples.();

    // MIDI output: index destination names, cache MIDIOut instances lazily
    MIDIClient.init;
    ~midiOuts = Dictionary.new;
    ~midiDeviceNames = MIDIClient.destinations.collect { |ep| ep.device }.as(Set);
    ~getMidiOut = { |deviceName|
        ~midiOuts[deviceName] ?? {
            var ep = MIDIClient.destinations.detect { |e| e.device == deviceName };
            if(ep.notNil) {
                var mo = MIDIOut.newByName(ep.device, ep.name);
                mo.latency = 0;
                ~midiOuts[deviceName] = mo;
                mo
            } { nil }
        }
    };

    // Send any cc<n> params as MIDI CC messages, e.g. cc1:0.5 -> control(chan, 1, 63)
    ~sendMidiCCs = { |midiOut, chans, params|
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(k.size > 2 && k.beginsWith("cc") && k.copyToEnd(2).every(_.isDecDigit)) {
                var ccNum = k.copyToEnd(2).asInteger;
                var ccVal = (val.asFloat * 127).clip(0, 127).round.asInteger;
                chans.do { |chan| midiOut.control(chan, ccNum, ccVal) };
            }
        }
    };

    // Known effects: key = param name, value = SynthDef name
    ~knownEffects = Dictionary.newFrom([
        \ngate,  \satoriGate,
        \reverb, \satoriReverb,
        \delay,  \satoriDelay,
        \chorus, \satoriChorus,
        \crush,  \satoriBitcrusher,
        \dist,   \satoriOverdrive,
        \fold,   \satoriFolder,
        \tape,   \satoriTape,
        \blur,   \satoriBlur,
        \feed,   \satoriFeed
    ]);

    // Default chain position for bare effect keys (no integer suffix).
    // Explicit integers (e.g. reverb1) always take precedence.
    ~effectDefaultOrder = Dictionary.newFrom([
        \ngate,  -1,
        \dist,   0,
        \crush,  1,
        \fold,   2,
        \chorus, 3,
        \delay,  4,
        \reverb, 5,
        \tape,   6,
        \blur,   7,
        \feed,   8
    ]);

    // Returns true for fx stream names: "fx" followed by one or more digits (e.g. fx0, fx1)
    ~isFxStream = { |stream|
        var str = stream.asString;
        str.beginsWith("fx") && { str.size > 2 } && { str.copyToEnd(2).every { |c| c.isDecDigit } }
    };

    ~getGroup = { |stream|
        ~groups[stream] ?? {
            var bus     = Bus.audio(s, 2);
            // fx stream groups live inside ~fxContainer (after all source groups);
            // source stream groups are inserted before ~fxContainer so they always run first
            var group   = if(~isFxStream.(stream)) {
                Group.new(~fxContainer, \addToTail)
            } {
                Group.new(~fxContainer, \addBefore)
            };
            var limiter = Synth.new(\satoriLimiter, [\in, bus.index, \out, 0], group, \addToTail);
            ~buses[stream]   = bus;
            ~limiters[stream] = limiter;
            ~groups[stream]  = group;
            ~effects[stream] = Dictionary.new;
            "Satori: created group for stream %".format(stream).postln;
            group
        }
    };

    // Extract SynthDef args for an effect instance from params, stripping the instance key prefix.
    // e.g. instanceKey=\reverb1, params={reverb1:0.5, reverb1room:0.8} -> [\wet, 0.5, \room, 0.8]
    // Legacy bare keys work the same: instanceKey=\reverb, params={reverb:0.5, reverbroom:0.8}
    ~effectParams = { |instanceKey, params|
        var prefix = instanceKey.asString;
        var pairs  = [];
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(k == prefix) {
                pairs = pairs ++ [\wet, val];
            } {
                if(k.beginsWith(prefix)) {
                    var suffix = k.copyToEnd(prefix.size);
                    // skip if suffix starts with a digit — that's another effect instance (e.g. "dist1" when prefix is "dist")
                    if(suffix.size > 0 && { suffix[0].isDecDigit.not }) {
                        pairs = pairs ++ [suffix.asSymbol, val];
                    }
                }
            }
        };
        if(params[\lag].notNil) { pairs = pairs ++ [\lag, params[\lag]] };
        pairs
    };

    ~applyEffects = { |stream, params, type="event"|
        var streamEffects = ~effects[stream];
        var instances = [];
        var activeKeys;
        var anchor;

        // Collect effect instances whose wet key is present in params.
        // Recognises bare legacy keys (e.g. \reverb) and ordered keys (e.g. \reverb1, \dist0).
        // Each entry: [instanceKey, synthDefName, orderIndex or nil for legacy]
        params.keysDo { |key|
            var k = key.asString;
            ~knownEffects.keysValuesDo { |effectName, synthDefName|
                var en = effectName.asString;
                if(k.beginsWith(en)) {
                    var rest = k.copyToEnd(en.size);
                    if(rest.isEmpty) {
                        instances = instances.add([key.asSymbol, synthDefName, ~effectDefaultOrder[effectName] ?? 999]);
                    } {
                        if(rest.every { |c| c.isDecDigit }) {
                            instances = instances.add([key.asSymbol, synthDefName, rest.asInteger]);
                        }
                    }
                }
            }
        };

        // Sort by order index ascending
        instances = instances.sort { |a, b| a[2] < b[2] };

        activeKeys = instances.collect { |i| i[0] }.as(Set);

        // Create or update synths for active instances
        instances.do { |inst|
            var instKey = inst[0];
            var defName = inst[1];
            var pairs   = [\in, ~buses[stream].index] ++ ~effectParams.(instKey, params);
            // resolve sidechain bus name strings (e.g. "bus0", "fx0") to bus indices
            pairs = pairs.clump(2).collect { |kv|
                if(kv[0] == \sidechain) { [\sidechain, ~resolveBusRef.(kv[1])] } { kv }
            }.flatten;
            if(streamEffects[instKey].isNil) {
                streamEffects[instKey] = Synth.new(defName, pairs, ~limiters[stream], \addBefore);
            } {
                streamEffects[instKey].set(*pairs);
            }
        };

        // Handle existing effects absent from this event
        streamEffects.keysValuesDo { |instKey, synth|
            if(activeKeys.includes(instKey).not) {
                if(type == "event") {
                    synth.set(\wet, 0);
                } {
                    var pairs = ~effectParams.(instKey, params);
                    if(pairs.size > 0) { synth.set(*pairs) };
                }
            }
        };

        // Enforce chain ordering: traverse instances in reverse, each moved before the previous anchor.
        // This builds: voices -> effect[0] -> effect[1] -> ... -> limiter
        anchor = ~limiters[stream];
        instances.reverseDo { |inst|
            var synth = streamEffects[inst[0]];
            if(synth.notNil) {
                synth.moveBefore(anchor);
                anchor = synth;
            }
        };
    };

    // Create or update send synths from sourceStream to any fx streams named in params.
    // For events: mute sends to fx streams not present in params.
    ~updateSends = { |sourceStream, params, type="event"|
        var sends = ~fxSends[sourceStream] ?? {
            ~fxSends[sourceStream] = Dictionary.new;
            ~fxSends[sourceStream]
        };
        var fxKeys = Set.new;
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(~isFxStream.(k)) {
                fxKeys.add(k);
                ~getGroup.(k); // ensure fx group/bus exists
                if(sends[k].isNil) {
                    sends[k] = Synth.new(\satoriSend, [
                        \in,  ~buses[sourceStream].index,
                        \out, ~buses[k].index,
                        \wet, val.asFloat
                    ], ~limiters[sourceStream], \addAfter);
                } {
                    sends[k].set(\wet, val.asFloat);
                }
            }
        };
        if(type == "event") {
            sends.keysValuesDo { |fxStream, synth|
                if(fxKeys.includes(fxStream).not) { synth.set(\wet, 0, \lag, 100) }
            }
        };
    };

    // Resolve a bus reference string to an audio bus index.
    // "bus0"–"bus3" -> ~sidechainBuses[n].index; any stream name -> ~buses[name].index; else -1.
    ~resolveBusRef = { |val|
        var str = val.asString;
        case
        { str.beginsWith("bus") && { str.copyToEnd(3).every { |c| c.isDecDigit } } } {
            var idx = str.copyToEnd(3).asInteger;
            if(idx < ~sidechainBuses.size) { ~sidechainBuses[idx].index } { -1 }
        }
        { ~buses[str.asSymbol].notNil } { ~buses[str.asSymbol].index }
        { -1 }
    };

    // Create or update send synths from sourceStream to any sidechain buses named in params (bus0–bus3).
    ~updateSidechainSends = { |sourceStream, params, type="event"|
        var sends = ~sidechainSends[sourceStream] ?? {
            ~sidechainSends[sourceStream] = Dictionary.new;
            ~sidechainSends[sourceStream]
        };
        var activeBuses = Set.new;
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(k.beginsWith("bus") && { k.copyToEnd(3).every { |c| c.isDecDigit } }) {
                var idx = k.copyToEnd(3).asInteger;
                if(idx < ~sidechainBuses.size) {
                    activeBuses.add(idx);
                    if(sends[idx].isNil) {
                        sends[idx] = Synth.new(\satoriSend, [
                            \in,  ~buses[sourceStream].index,
                            \out, ~sidechainBuses[idx].index,
                            \wet, val.asFloat
                        ], ~limiters[sourceStream], \addAfter);
                    } {
                        sends[idx].set(\wet, val.asFloat);
                    }
                }
            }
        };
        if(type == "event") {
            sends.keysValuesDo { |idx, synth|
                if(activeBuses.includes(idx).not) { synth.set(\wet, 0, \lag, 100) }
            }
        };
    };

    ~getVoices = { |stream|
        ~voices[stream] ?? {
            ~voices[stream]      = Dictionary.new;
            ~voiceOrder[stream]  = List.new;
            ~voiceTokens[stream] = Dictionary.new;
            ~voices[stream]
        }
    };

    ~getMidiVoices = { |stream|
        ~midiVoices[stream] ?? {
            ~midiVoices[stream]     = Dictionary.new;
            ~midiVoiceOrder[stream] = List.new;
            ~midiVoices[stream]
        }
    };

    // Normalise cut value to an array of stream name strings
    // Accepts: 0, "s0", "0,1", "s0,s1", "all"
    ~resolveStreams = { |cut|
        if(cut.asString == "all") {
            ~voices.keys.asArray
        } {
            cut.asString.split($,).collect { |item|
                var t = item.asString.stripWhiteSpace;
                if(t.every { |c| c.isDecDigit }) { "s" ++ t } { t }
            }
        }
    };

    ~cutStreams = { |cut, cutr = 5|
        ~resolveStreams.(cut).do { |stream|
            ~voices[stream].do { |synth| synth.set(\r, cutr, \gate, 0) };
            ~voices[stream]      = Dictionary.new;
            ~voiceOrder[stream]  = List.new;
            ~voiceTokens[stream] = Dictionary.new; // new dict invalidates all pending strum callbacks
            ~midiVoices[stream].do { |voice|
                voice[\chans].do { |chan| voice[\midiOut].noteOff(chan, voice[\note], 0) };
            };
            ~midiVoices[stream]     = Dictionary.new;
            ~midiVoiceOrder[stream] = List.new;
        };
    };

    ~releaseVoice = { |stream, note|
        var v = ~voices[stream];
        if(v.notNil && v[note].notNil) {
            v[note].set(\gate, 0);
            v.removeAt(note);
            ~voiceOrder[stream].remove(note);
        };
    };

    ~releaseMidiVoice = { |stream, note|
        var v = ~midiVoices[stream];
        if(v.notNil && v[note].notNil) {
            var voice = v[note];
            voice[\chans].do { |chan| voice[\midiOut].noteOff(chan, note, 0) };
            v.removeAt(note);
            ~midiVoiceOrder[stream].remove(note);
        };
    };

    // Expand params for a chord. Array params (comma-separated strings) are cycled per voice;
    // scalar params are copied to every voice. n is set per-voice from the notes array.
    ~expandChord = { |params, notes|
        notes.collect { |note, i|
            var d = Dictionary.new;
            params.keysValuesDo { |k, v|
                var parts = v.asString.split($,);
            d[k] = if(parts.size > 1) { parts.wrapAt(i).asFloat } { v };
            };
            d[\n] = note;
            d
        }
    };

    // Route all /satori/* messages
    ~satoriHandler = { |msg, time, replyAddr, recvPort|
        var path = msg[0].asString;

        if(path.beginsWith("/satori/")) {
            var parts     = path.split($/).reject { |s| s.isEmpty };
            var stream    = parts[1]; // e.g. "s0"
            var type      = parts[2]; // "event" or "mutation"
            var params    = ~parseParams.(msg[1..]);
            var cycleTime = (params[\time] ?? 0).asFloat;
            var cps       = (params[\cps] ?? 0.5).asFloat;
            var streamOut   = params.removeAt(\out);   // routing: handled via limiter, not forwarded to synths
            var streamLevel = params.removeAt(\level); // final fader: applied to limiter, not forwarded to synths
            params.removeAt(\time); // don't forward scheduling metadata to synths

            // Ensure group/bus infrastructure exists immediately (before scheduling)
            ~getGroup.(stream);

            ~syncClock.(cps, cycleTime);

            ~satoriClock.schedAbs(cycleTime, {
            
                if(streamOut.notNil) {
                    ~limiters[stream].set(\out, streamOut.asInteger % ~numOutputs);
                };
                if(streamLevel.notNil) {
                    ~limiters[stream].set(\level, streamLevel.asFloat);
                };

                if(type == "mutation") {
                    var pairs = params.getPairs;
                    ~voices[stream].do { |synth| synth.set(*pairs) };
                    ~midiVoices[stream].do { |voice|
                        var amp = params[\amp];
                        if(amp.notNil) {
                            var vel = (amp.asFloat * 127).clip(0, 127).round.asInteger;
                            voice[\chans].do { |chan| voice[\midiOut].polyTouch(chan, voice[\note], vel) };
                        };
                        ~sendMidiCCs.(voice[\midiOut], voice[\chans], params);
                    };
                    ~applyEffects.(stream, params, "mutation");
                    if(~isFxStream.(stream).not) { ~updateSends.(stream, params, "mutation") };
                    ~updateSidechainSends.(stream, params, "mutation");
                };

                if(type == "event") {
                    var inst = params[\inst];

                    // Resolve inst:'sampler' or inst:'granular' + bank/i to a buffer
                    if([\sampler, \granular, \granular2].includes(inst.asSymbol)) {

                        var bank = params[\bank].asSymbol;
                        var idx  = (params[\i] ?? 0).asInteger;
                        var bufs = ~banks[bank];

                        if(bufs.notNil && { bufs.size > 0 }) {
                            var bufIdx = idx % bufs.size;
                            params[\buf] = bufs[bufIdx].bufnum;
                        } {
                            "Satori: bank '%' not found or empty".format(bank).postln;
                        };
                    };

                    if(params[\cut].notNil) { ~cutStreams.(params[\cut], params[\cutr] ?? 5) };
                    ~applyEffects.(stream, params);
                    if(~isFxStream.(stream).not) { ~updateSends.(stream, params) };
                    ~updateSidechainSends.(stream, params);

                    if(~isFxStream.(stream).not) {
                        var midi      = params[\midi];
                        var nudge     = (params[\nudge]     ?? 0).asFloat / 1000;
                        var strum     = (params[\strum]     ?? 0).asFloat / 1000;
                        var mididelay = (params[\mididelay] ?? 0).asFloat / 1000;

                        if(midi.notNil) {
                            var midiOut = ~getMidiOut.(midi.asString);
                            if(midiOut.notNil) {
                                var notes  = (params[\n] ?? 60).asString.split($,).collect(_.asInteger);
                                var dur    = (params[\dur] ?? 250).asFloat / 1000;
                                var vel    = ((params[\amp] ?? 0.8).asFloat * 127).clip(0, 127).round.asInteger;
                                var chans  = if(params[\midichan].notNil) {
                                    [params[\midichan].asInteger]
                                } {
                                    (0..15)
                                };
                                var voices = ~getMidiVoices.(stream);
                                var order  = ~midiVoiceOrder[stream];

                                notes.do { |note|
                                    var midiVoice;
                                    var start    = nudge + (strum * i) + mididelay;
                                    var end      = start + dur;
                                    ~releaseMidiVoice.(stream, note);
                                    if(voices.size >= 8) { ~releaseMidiVoice.(stream, order.first) };

                                    midiVoice = Dictionary.newFrom([\midiOut, midiOut, \note, note, \chans, chans]);
                                    voices[note] = midiVoice;
                                    order.add(note);

                                    SystemClock.sched(start, {
                                        chans.do { |chan| midiOut.noteOn(chan, note, vel) };
                                        ~sendMidiCCs.(midiOut, chans, params);
                                        SystemClock.sched(end, {
                                            if(~midiVoices[stream].notNil && (~midiVoices[stream][note] === midiVoice)) {
                                                ~releaseMidiVoice.(stream, note)
                                            };
                                            nil
                                        });
                                        nil
                                    });
                                };
                            } { "Satori: MIDI device '%' not found".format(midi).postln };
                        };

                        if(inst.notNil && SynthDescLib.global.at(inst.asSymbol).notNil) {
                            var notes = (params[\n] ?? params[\freq] ?? 60).asString.split($,)
                                .collect(_.asFloat)
                                .asSet.asArray.sort; // unique and sorted
                            var voices   = ~getVoices.(stream);
                            var order    = ~voiceOrder[stream];
                            var tokens   = ~voiceTokens[stream];
                            var expanded = ~expandChord.(params, notes);
                            // Bump per-note token for every note in this event before any strum
                            // callbacks are scheduled. Each callback checks its captured token
                            // against the live dict — a newer event or a cut will invalidate it.
                            var myTokens = notes.collect { |note|
                                var t = (tokens[note] ?? 0) + 1;
                                tokens[note] = t;
                                t
                            };

                            expanded.do { |vParams, i|
                                var note     = vParams[\n];
                                var dur      = (vParams[\dur] ?? 250).asFloat / 1000;
                                var myToken  = myTokens[i];
                                var synth;
                                var start    = nudge + (strum * i);
                                var end      = start + dur;

                                SystemClock.sched(start, {
                                    // Bail if a newer event claimed this note, or a cut flushed the stream
                                    if(~voiceTokens[stream] === tokens && tokens[note] == myToken) {
                                        synth = Synth(inst.asSymbol, vParams.getPairs ++ [\out, ~buses[stream].index], ~groups[stream], \addToHead);
                                        ~releaseVoice.(stream, note);
                                        if(voices.size >= 8) { ~releaseVoice.(stream, order.first) };
                                        voices[note] = synth;
                                        order.add(note);

                                        SystemClock.sched(end, {
                                            if(~voices[stream].notNil && (~voices[stream][note] === synth)) {
                                                ~releaseVoice.(stream, note)
                                            };
                                            nil
                                        });
                                    };
                                    nil
                                });
                            };
                        } {
                            if(inst.notNil) { "Satori: no SynthDef found for inst '%'".format(inst).postln };
                        };
                    };
                };

            nil }); // end schedAbs
        }
    };

    thisProcess.addOSCRecvFunc(~satoriHandler);
    "Satori: listening for OSC on port %".format(NetAddr.langPort).postln;
};