module linenoised_test;

import linenoised;

void main() {
    import std.stdio;
    import std.conv : to;
    while (1) {
        auto text = to!string(linenoise( "> "));
        writeln(text);
        if (text == "exit") return;
    }
}

