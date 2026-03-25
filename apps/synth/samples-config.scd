// samples-config.scd
// List root directories to scan for sample banks.
// Each subdirectory becomes a named bank — e.g. ~/samples/kicks/ -> bank 'kicks'.
// Supports ~ expansion. Add as many directories as you like.

~sampleDirs = [
    // "~/samples",
    // "/path/to/more/samples",
];

// Maximum number of samples to load per bank (files are sorted alphabetically, first N are kept)
~maxBuffersPerBank = 16;
~detectTransients = false; // whether to detect zero crossings for each sample and make them available as markers for snapping
