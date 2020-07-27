module linenoised_test;

import linenoised;

void dbug(string s) {
    import std.stdio;

    std.stdio.stderr.writeln(s);
}

void completion(const char* buf, linenoiseCompletions lc) {
    import std.string;

    if (buf[0] == 'h') {
        linenoiseAddCompletion(lc, cast(char*) "hello".toStringz);
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
        dbug(text is null ? "null" : to!string(text));
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
