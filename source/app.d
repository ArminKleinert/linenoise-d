module linenoised_test;

import linenoised;

void main() {
    import std.stdio;
    import std.conv : to;
    while (1) {
        auto text = linenoise( "> ");
        linenoiseHistoryAdd(text);
        auto outtext = to!string(text);
        writeln(outtext);
        if (outtext == "exit") return;
    }
}

