s.waitForBoot {

    // Reconstruct a Dictionary from interleaved [key, val, key, val, ...] OSC args
    ~parseParams = { |args|
        var dict = Dictionary.new;
        args.clump(2).do { |pair| dict[pair[0].asSymbol] = pair[1] };
        dict
    };

    // Route all /satori/* messages
    ~satoriHandler = { |msg, time, replyAddr, recvPort|
        var path = msg[0].asString;

        if(path.beginsWith("/satori/")) {
            var parts = path.split($/).reject { |s| s.isEmpty };
            var stream  = parts[1]; // e.g. "s0"
            var type   = parts[2]; // "event" or "mutation"
            var params = ~parseParams.(msg[1..]);

            [stream, type, params].postln;
        }
    };

    thisProcess.addOSCRecvFunc(~satoriHandler);
    "Satori: listening for OSC on port %".format(NetAddr.langPort).postln;

};
