// config.scd

// Audio device name — set to nil to use the system default
~device = nil;
// ~device = "My Interface Name";

// Number of hardware output channels on the device
~numOutputs = 16;

// Sample directories to scan for banks.
// Each subdirectory becomes a named bank — e.g. ~/samples/kicks/ -> bank 'kicks'.
// Supports ~ expansion. Add as many directories as you like.
~sampleDirs = [
    // "~/samples",
    // "/path/to/more/samples",
    // "/Users/peterthomas/Documents/personal-development/satori-samples/samples"
];

// Maximum number of samples to load per bank (files are sorted alphabetically, first N are kept)
~maxBuffersPerBank = 16;
~detectTransients = false; // whether to detect zero crossings for each sample and make them available as markers for snapping
