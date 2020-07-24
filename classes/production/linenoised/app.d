import core.sys.posix.termios;
import core.sys.posix.unistd;
import core.stdc.stdio;
import core.stdc.errno;
import core.stdc.string;
import core.stdc.stdlib;
import core.stdc.ctype;
import core.sys.posix.sys.stat;
import core.sys.posix.sys.types;
import core.sys.posix.sys.ioctl;
import core.sys.posix.unistd;

struct linenoiseCompletions {
    size_t len;
    char** cvec;
}

alias linenoiseCompletionCallback = void delegate(const char*, linenoiseCompletions*);
alias linenoiseHintsCallback = void delegate(const char*, int* color, int* bold);
alias linenoiseFreeHintsCallback = void delegate(void*);

const int LINENOISE_DEFAULT_HISTORY_MAX_LEN = 100;
const int LINENOISE_MAX = 4096;
const char*[4] unsupported_term = ["dumb", "cons25", "emacs", null];

linenoiseCompletionCallback* completionCallback = null;
linenoiseHintsCallback* hintsCallback = null;
linenoiseFreeHintsCallback* freeHintsCallback = null;

termios orig_termios; /* In order to restore at exit.*/
int maskmode = 0; /* Show "***" instead of input. For passwords. */
int rawmode = 0; /* For atexit() function to check if restore is needed*/
int mlmode = 0; /* Multi line mode. Default is single line. */
int atexit_registered = 0; /* Register atexit just 1 time. */
int history_max_len = LINENOISE_DEFAULT_HISTORY_MAX_LEN;
int history_len = 0;
char** history = null;

/* The linenoiseState structure represents the state during line editing.
 * We pass this state to functions implementing specific editing
 * functionalities. */
struct linenoiseState {
    int ifd; /* Terminal stdin file descriptor. */
    int ofd; /* Terminal stdout file descriptor. */
    char* buf; /* Edited line buffer. */
    size_t buflen; /* Edited line buffer size. */
    const char* prompt; /* Prompt to display. */
    size_t plen; /* Prompt length. */
    size_t pos; /* Current cursor position. */
    size_t oldpos; /* Previous refresh cursor position. */
    size_t len; /* Current edited line length. */
    size_t cols; /* Number of columns in terminal. */
    size_t maxrows; /* Maximum num of rows used so far (multiline mode) */
    int history_index; /* The history index we are currently editing. */
}

enum KEY_ACTION {
    KEY_NULL = 0, /* NULL */
    CTRL_A = 1, /* Ctrl+a */
    CTRL_B = 2, /* Ctrl-b */
    CTRL_C = 3, /* Ctrl-c */
    CTRL_D = 4, /* Ctrl-d */
    CTRL_E = 5, /* Ctrl-e */
    CTRL_F = 6, /* Ctrl-f */
    CTRL_H = 8, /* Ctrl-h */
    TAB = 9, /* Tab */
    CTRL_K = 11, /* Ctrl+k */
    CTRL_L = 12, /* Ctrl+l */
    ENTER = 13, /* Enter */
    CTRL_N = 14, /* Ctrl-n */
    CTRL_P = 16, /* Ctrl-p */
    CTRL_T = 20, /* Ctrl-t */
    CTRL_U = 21, /* Ctrl+u */
    CTRL_W = 23, /* Ctrl+w */
    ESC = 27, /* Escape */
    BACKSPACE = 127 /* Backspace */
}

/*
typedef void(linenoiseCompletionCallback)(const char *, linenoiseCompletions *);
typedef char*(linenoiseHintsCallback)(const char *, int *color, int *bold);
typedef void(linenoiseFreeHintsCallback)(void *);
void linenoiseSetCompletionCallback(linenoiseCompletionCallback *);
void linenoiseSetHintsCallback(linenoiseHintsCallback *);
void linenoiseSetFreeHintsCallback(linenoiseFreeHintsCallback *);
void linenoiseAddCompletion(linenoiseCompletions *, const char *);

char *linenoise(const char *prompt);
void linenoiseFree(void *ptr);
int linenoiseHistoryAdd(const char *line);
int linenoiseHistorySetMaxLen(int len);
int linenoiseHistorySave(const char *filename);
int linenoiseHistoryLoad(const char *filename);
void linenoiseClearScreen(void);
void linenoiseSetMultiLine(int ml);
void linenoisePrintKeyCodes(void);
void linenoiseMaskModeEnable(void);
void linenoiseMaskModeDisable(void);
*/

void main() {
    termios t;
}
