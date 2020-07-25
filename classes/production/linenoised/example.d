module linenoised_test;

import linenoised;

void completion(const char* buf, linenoiseCompletions lc) {
    if (buf[0] == 'h') {
        linenoiseAddCompletion(lc, "hello");
        linenoiseAddCompletion(lc, "hello there");
    }
}

char* hints(const char* buf, int* color, int* bold) {
    import std.string;

    if (!icmp(fromStringz(buf), "i")) {
        *color = 33;
        *bold = 0;
        return cast(char*)("rb");
    }
    return null;
}

void main() {
    import std.stdio;
    import std.conv : to;
    import std.string : toStringz;

    int ml = 0;
    linenoiseSetCompletionCallback(&completion);
    linenoiseSetHintsCallback(&hints);

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
        if (outtext == "clear")
            linenoiseClearScreen();
        writeln(outtext);
        if (outtext == "exit")
            return;
    }
}
