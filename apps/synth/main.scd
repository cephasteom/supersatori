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

    // Parallel TempoClock driven by incoming cps + cycle position
    ~satoriClock = nil;
    ~clockCps    = nil;

    // Satori sends events ~.1 second before their intended play time.
    // We anchor the clock so that beat cycleTime fires .1 second from now,
    // matching that lookahead. This de-jitters WebSocket timing variance.
    ~lookahead = 0.1; // seconds — match Satori's JS-side lookahead

    ~syncClock = { |cps, cycleTime|
        var needsResync = false;
        if(~satoriClock.isNil) {
            needsResync = true;
        } {
            var expectedCycleTime = ~satoriClock.beats;
            // Detect restart: cycleTime jumped backwards relative to where the clock thinks we are
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
    ~voices     = Dictionary.new; // stream -> Dictionary(note -> synth)
    ~voiceOrder = Dictionary.new; // stream -> List of notes (oldest first)
    ~fxSends    = Dictionary.new; // sourceStream -> Dictionary(fxStreamName -> sendSynth)

    // Container group that always runs after all source stream groups; fx groups live inside it
    ~fxContainer = Group.new(s, \addToTail);

    // Sample banks: bankName -> Array of Buffers (sorted by filename)
    ~banks = Dictionary.new;
    // Zero-crossing snap points: bankName -> Array of Arrays of Float (0-1 positions)
    ~transients = Dictionary.new;

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

                            if(~detectTransients) {
                                // If enabled, detect zero crossings for each sample in a background thread and store as markers for snapping
                                // Analyse zero crossings in a background thread (one read per file)
                                fork {
                                    var snapPoints = Array.newClear(files.size);
                                    files.do { |f, i|
                                        var sf      = SoundFile.new;
                                        var markers = [0.0];
                                        if(sf.openRead(f.fullPath)) {
                                            var nFrames    = sf.numFrames;
                                            var nChans     = sf.numChannels;
                                            var numMarkers = 256;
                                            var stride     = max(1, (nFrames / numMarkers).floor).asInteger;
                                            var data       = FloatArray.newClear(nFrames * nChans);
                                            sf.readData(data);
                                            sf.close;
                                            numMarkers.do { |chunk|
                                                var searchStart = (chunk * stride).asInteger;
                                                var windowEnd   = min(searchStart + stride, nFrames - 1).asInteger;
                                                var found = false;
                                                (windowEnd - searchStart).do { |j|
                                                    var frame = searchStart + j;
                                                    if(found.not) {
                                                        if(data[frame * nChans] * data[(frame + 1) * nChans] <= 0) {
                                                            markers = markers.add(frame / nFrames);
                                                            found = true;
                                                        }
                                                    }
                                                };
                                                0.yield; // yield between each window so OSC handlers can run
                                            };
                                        } { sf.close };
                                        snapPoints[i] = markers;
                                    };
                                    ~transients[bankName] = snapPoints;
                                    "Satori: transients ready fo;r bank '%'".format(bankName).postln;
                                };
                            };
                        }
                    }
                } {
                    "Satori: sample dir not found: %".format(dir).postln;
                }
            }
    };

    ~loadSamples.();

    // Known effects: key = param name, value = SynthDef name
    ~knownEffects = Dictionary.newFrom([
        \reverb, \satoriReverb,
        \delay,  \satoriDelay,
        \chorus, \satoriChorus,
        \crush,  \satoriBitcrusher,
        \dist,   \satoriOverdrive,
        \fold,   \satoriFolder
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

    // Extract params for an effect by stripping its name prefix
    // e.g. (reverb, {reverb: 0.5, reverbroom: 0.8}) -> [\wet, 0.5, \size, 0.8]
    // Extract SynthDef args for an effect from params, stripping the effect name prefix
    // e.g. effectName=reverb, params={reverb:0.5, reverbroom:0.8} -> [\wet, 0.5, \size, 0.8]
    ~effectParams = { |effectName, params|
        var prefix = effectName.asString;
        var pairs  = [];
        params.keysValuesDo { |key, val|
            var k = key.asString;
            if(k == prefix) {
                pairs = pairs ++ [\wet, val];
            } {
                if(k.beginsWith(prefix)) {
                    pairs = pairs ++ [k.copyToEnd(prefix.size).asSymbol, val];
                }
            }
        };
        if(params[\lag].notNil) { pairs = pairs ++ [\lag, params[\lag]] };
        pairs
    };

    ~applyEffects = { |stream, params, type="event"|
        var streamEffects = ~effects[stream];
        ~knownEffects.keysValuesDo { |effectName, synthDefName|
            var wet = params[effectName];
            if(wet.notNil) {
                var pairs = [\in, ~buses[stream].index] ++ ~effectParams.(effectName, params);
                if(streamEffects[effectName].isNil) {
                    streamEffects[effectName] = Synth.new(
                        synthDefName, pairs, ~limiters[stream], \addBefore
                    );
                } {
                    streamEffects[effectName].set(*pairs);
                }
            } {
                if(type == "mutation" && streamEffects[effectName].notNil) {
                    // apply sub-params (e.g. reverbroom) even without wet
                    var pairs = ~effectParams.(effectName, params);
                    if(pairs.size > 0) { streamEffects[effectName].set(*pairs) };
                };
                // if an event, set the wet param to 0 to bypass the effect if it's not included in the params
                if(type == "event" && streamEffects[effectName].notNil) {
                    streamEffects[effectName].set(\wet, 0);
                };
            }
        }
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
                if(fxKeys.includes(fxStream).not) { synth.set(\wet, 0) }
            }
        };
    };

    ~getVoices = { |stream|
        ~voices[stream] ?? {
            ~voices[stream]     = Dictionary.new;
            ~voiceOrder[stream] = List.new;
            ~voices[stream]
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
            ~voices[stream]     = Dictionary.new;
            ~voiceOrder[stream] = List.new;
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

    // Route all /satori/* messages
    ~satoriHandler = { |msg, time, replyAddr, recvPort|
        var path = msg[0].asString;

        if(path.beginsWith("/satori/")) {
            var parts     = path.split($/).reject { |s| s.isEmpty };
            var stream    = parts[1]; // e.g. "s0"
            var type      = parts[2]; // "event" or "mutation"
            var params    = ~parseParams.(msg[1..]);
            var cycleTime = (params[\time] ?? 0).asFloat;
            var cps       = (params[\cps]  ?? 0.5).asFloat;
            var streamOut = params.removeAt(\out); // routing: handled via limiter, not forwarded to synths
            
            params.removeAt(\time); // don't forward scheduling metadata to synths

            // Ensure group/bus infrastructure exists immediately (before scheduling)
            ~getGroup.(stream);

            ~syncClock.(cps, cycleTime);

            ~satoriClock.schedAbs(cycleTime, {
            
            if(streamOut.notNil) {
                ~limiters[stream].set(\out, streamOut.asInteger % ~numOutputs);
            };

            if(type == "mutation") {
                var pairs = params.getPairs;
                ~voices[stream].do { |synth| synth.set(*pairs) };
                ~applyEffects.(stream, params, "mutation");
                if(~isFxStream.(stream).not) { ~updateSends.(stream, params, "mutation") };
            };

            if(type == "event") {
                var inst = params[\inst];

                // Resolve inst:'sampler' or inst:'granular' + bank/i to a buffer
                if([\sampler, \granular].includes(inst.asSymbol)) {

                    var bank = params[\bank].asSymbol;
                    var idx  = (params[\i] ?? 0).asInteger;
                    var bufs = ~banks[bank];

                    if(bufs.notNil && { bufs.size > 0 }) {
                        var bufIdx = idx % bufs.size;
                        params[\buf] = bufs[bufIdx].bufnum;

                        // snap begin to nearest zero crossing if specified (sampler only)
                        if(inst.asSymbol == \sampler) {
                            var begin = params[\begin] ?? 0;
                            var stt   = params[\stt] ?? 0;
                            if(begin.asBoolean && stt.asBoolean) {
                                var markers = ~transients[bank] ?? [];
                                if(markers.notNil && { markers.size > 0 }) {
                                    params[\begin] = markers.minItem { |m| (m - begin).abs };
                                }
                            };
                        };
                    } {
                        "Satori: bank '%' not found or empty".format(bank).postln;
                    };
                };

                if(params[\cut].notNil) { ~cutStreams.(params[\cut], params[\cutr] ?? 5) };
                ~applyEffects.(stream, params);
                if(~isFxStream.(stream).not) { ~updateSends.(stream, params) };

                if(~isFxStream.(stream).not && inst.notNil && SynthDescLib.global.at(inst.asSymbol).notNil) {
                    var dur    = (params[\dur] ?? 250) / 1000;
                    var note   = params[\n] ?? 60;
                    var voices = ~getVoices.(stream);
                    var order  = ~voiceOrder[stream];
                    var synth;

                    ~releaseVoice.(stream, note);
                    if(voices.size >= 8) { ~releaseVoice.(stream, order.first) };

                    synth = Synth(inst.asSymbol, params.getPairs ++ [\out, ~buses[stream].index], ~groups[stream], \addToHead);
                    voices[note] = synth;
                    order.add(note);

                    SystemClock.sched(dur, {
                        if(~voices[stream].notNil && (~voices[stream][note] === synth)) {
                            ~releaseVoice.(stream, note)
                        };
                        nil
                    });
                } {
                    if(inst.notNil) { "Satori: no SynthDef found for inst '%'".format(inst).postln };
                };
            };

            nil }); // end schedAbs
        }
    };

    thisProcess.addOSCRecvFunc(~satoriHandler);
    "Satori: listening for OSC on port %".format(NetAddr.langPort).postln;
};