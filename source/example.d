module linenoised_test;

import linenoised;

void main() {
    import std.stdio;
    import std.conv : to;

    import std.regex : ctRegex;

    int ml = 0;

    while (1) {
        auto text = linenoise("> ");
        linenoiseHistoryAdd(text);
        auto outtext = to!string(text);
        if (outtext == "multiline")
            linenoiseSetMultiLine(ml ^= 1);
        if (outtext == "maskon")
            linenoiseMaskModeEnable();
        if (outtext == "maskoff")
            linenoiseMaskModeDisable();
        if (outtext == "showcodes")
            linenoisePrintKeyCodes();
        if (outtext == "beep")
            linenoiseBeep();
        writeln(outtext);
        if (outtext == "exit")
            return;
    }
}
