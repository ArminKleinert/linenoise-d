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

import std.string : icmp, toStringz;
import std.conv : to;

struct linenoiseCompletions {
  size_t len;
  char** cvec;
}

alias linenoiseCompletionCallback = void function(const char*, linenoiseCompletions*);
alias linenoiseHintsCallback = char* function(const char *, int *color, int *bold);
alias linenoiseFreeHintsCallback = void function(void*);

const int LINENOISE_DEFAULT_HISTORY_MAX_LEN = 100;
const int LINENOISE_MAX_LINE = 4096;

private const string[4] unsupported_term = ["dumb", "cons25", "emacs", null];
private linenoiseCompletionCallback completionCallback = null;
private linenoiseHintsCallback hintsCallback = null;
private linenoiseFreeHintsCallback freeHintsCallback = null;

private termios orig_termios; /* In order to restore at exit.*/
private int maskmode = 0; /* Show "***" instead of input. For passwords. */
private int rawmode = 0; /* For atexit() function to check if restore is needed*/
private int mlmode = 0;  /* Multi line mode. Default is single line. */
private int atexit_registered = 0; /* Register atexit just 1 time. */
private int history_max_len = LINENOISE_DEFAULT_HISTORY_MAX_LEN;
private int history_len = 0;
private char **history = null;

/* The linenoiseState structure represents the state during line editing.
 * We pass this state to functions implementing specific editing
 * functionalities. */
struct linenoiseState {
    int ifd;            /* Terminal stdin file descriptor. */
    int ofd;            /* Terminal stdout file descriptor. */
    char *buf;          /* Edited line buffer. */
    size_t buflen;      /* Edited line buffer size. */
    const char *prompt; /* Prompt to display. */
    size_t plen;        /* Prompt length. */
    size_t pos;         /* Current cursor position. */
    size_t oldpos;      /* Previous refresh cursor position. */
    size_t len;         /* Current edited line length. */
    size_t cols;        /* Number of columns in terminal. */
    size_t maxrows;     /* Maximum num of rows used so far (multiline mode) */
    int history_index;  /* The history index we are currently editing. */
}

enum KEY_ACTION {
	KEY_NULL = 0,	    /* NULL */
	CTRL_A = 1,         /* Ctrl+a */
	CTRL_B = 2,         /* Ctrl-b */
	CTRL_C = 3,         /* Ctrl-c */
	CTRL_D = 4,         /* Ctrl-d */
	CTRL_E = 5,         /* Ctrl-e */
	CTRL_F = 6,         /* Ctrl-f */
	CTRL_H = 8,         /* Ctrl-h */
	TAB = 9,            /* Tab */
	CTRL_K = 11,        /* Ctrl+k */
	CTRL_L = 12,        /* Ctrl+l */
	ENTER = 13,         /* Enter */
	CTRL_N = 14,        /* Ctrl-n */
	CTRL_P = 16,        /* Ctrl-p */
	CTRL_T = 20,        /* Ctrl-t */
	CTRL_U = 21,        /* Ctrl+u */
	CTRL_W = 23,        /* Ctrl+w */
	ESC = 27,           /* Escape */
	BACKSPACE =  127    /* Backspace */
}

private extern (C) void function() linenoiseAtExit;
int linenoiseHistoryAdd(const char *line);
private void refreshLine(linenoiseState *l);

/* ======================= Low level terminal handling ====================== */

/* Enable "mask mode". When it is enabled, instead of the input that
 * the user is typing, the terminal will just display a corresponding
 * number of asterisks, like "****". This is useful for passwords and other
 * secrets that should not be displayed. */
void linenoiseMaskModeEnable() {
	maskmode = 1;
}

/* Disable mask mode. */
void linenoiseMaskModeDisable() {
	maskmode = 0;
}

/* Set if to use or not the multi line mode. */
void linenoiseSetMultiLine(int ml) {
	mlmode = ml;
}

/* Return true if the terminal name is in the list of terminals we know are
 * not able to understand basic escape sequences. */
private int isUnsupportedTerm() {
	char *term1 = getenv("TERM");

	if (term1 == null) return 0;
    string term = to!string(term1);
	for (int j = 0; j < unsupported_term.length; j++) {
		if (term.icmp(unsupported_term[j]) == 0)
			return 1;
	}
	return 0;
}

/* Raw mode: 1960 magic shit. */
private int enableRawMode(int fd) {
    termios raw;

    if (!isatty(STDIN_FILENO)) goto fatal;
    if (!atexit_registered) {
		atexit(linenoiseAtExit);
		atexit_registered = 1;
	}
    if (tcgetattr(fd,&orig_termios) == -1) goto fatal;

    raw = orig_termios;  /* modify the original mode */
    /* input modes: no break, no CR to NL, no parity check, no strip char,
     * no start/stop output control. */
    raw.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    /* output modes - disable post processing */
    raw.c_oflag &= ~(OPOST);
    /* control modes - set 8 bit chars */
    raw.c_cflag |= (CS8);
    /* local modes - choing off, canonical off, no extended functions,
     * no signal chars (^Z,^C) */
    raw.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    /* control chars - set return condition: min number of bytes and timer.
     * We want read to return every single byte, without timeout. */
    raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0; /* 1 byte, no timer */

    /* put terminal in raw mode after flushing */
    if (tcsetattr(fd,TCSAFLUSH,&raw) < 0) goto fatal;
    rawmode = 1;
    return 0;

fatal:
errno = ENOTTY;
    return -1;
}

private void disableRawMode(int fd) {
    /* Don't even check the return value as it's too late. */
    if (rawmode && tcsetattr(fd,TCSAFLUSH,&orig_termios) != -1)
        rawmode = 0;
}

/* Use the ESC [6n escape sequence to query the horizontal cursor position
 * and return it. On error -1 is returned, on success the position of the
 * cursor. */
private int getCursorPosition(int ifd, int ofd) {
    char[32] buf;
    auto buf_ptr = buf.ptr;
    int cols, rows;
    uint i = 0;

    /* Report cursor location */
    if (write(ofd, toStringz("\x1b[6n"), 4) != 4) return -1;

    /* Read the response: ESC [ rows ; cols R */
    while (i < buf.sizeof-1) {
        if (read(ifd,buf_ptr+i,1) != 1) break;
        if (buf[i] == 'R') break;
        i++;
    }
    buf[i] = '\0';

    /* Parse it. */
    if (buf[0] != KEY_ACTION.ESC || buf[1] != '[') return -1;
    if (sscanf(buf_ptr+2,"%d;%d",&rows,&cols) != 2) return -1;
    return cols;
}


/* Try to get the number of columns in the current terminal, or assume 80
 * if it fails. */
private int getColumns(int ifd, int ofd) {
    winsize ws;

    if (ioctl(1, TIOCGWINSZ, &ws) == -1 || ws.ws_col == 0) {
        /* ioctl() failed. Try to query the terminal itself. */
        int start, cols;

        /* Get the initial position so we can restore it later. */
        start = getCursorPosition(ifd,ofd);
        if (start == -1) goto failed;

        /* Go to right margin and get position. */
        if (write(ofd,toStringz("\x1b[999C"),6) != 6) goto failed;
        cols = getCursorPosition(ifd,ofd);
        if (cols == -1) goto failed;

        /* Restore position. */
        if (cols > start) {
            char[32] seq;
            auto seq_ptr = seq.ptr;
            snprintf(seq_ptr,32,toStringz("\x1b[%dD"),cols-start);
            if (write(ofd,seq_ptr,strlen(seq_ptr)) == -1) {
                /* Can't recover... */
            }
        }
        return cols;
    } else {
        return ws.ws_col;
    }

failed:
return 80;
}

/* Clear the screen. Used to handle ctrl+l */
void linenoiseClearScreen() {
    if (write(STDOUT_FILENO,toStringz("\x1b[H\x1b[2J"),7) <= 0) {
        /* nothing to do, just to avoid warning. */
    }
}

/* Beep, used for completion when there is nothing to complete or when all
 * the choices were already shown. */
void linenoiseBeep() {
    fprintf(stderr, toStringz("\x07"));
    fflush(stderr);
}


/* ============================== Completion ================================ */

/* Free a list of completion option populated by linenoiseAddCompletion(). */
private void freeCompletions(linenoiseCompletions *lc) {
    size_t i;
    for (i = 0; i < (*lc).len; i++)
        free((*lc).cvec[i]);
    if ((*lc).cvec != null)
        free((*lc).cvec);
}

/* This is an helper function for linenoiseEdit() and is called when the
 * user types the <tab> key in order to complete the string currently in the
 * input.
 *
 * The state of the editing is encapsulated into the pointed linenoiseState
 * structure as described in the structure definition. */
private int completeLine(linenoiseState *ls) {
    linenoiseCompletions lc = { 0, null };
    ssize_t nread, nwritten;
    char c = 0;

    completionCallback((*ls).buf,&lc);
    if (lc.len == 0) {
        linenoiseBeep();
    } else {
        size_t stop = 0, i = 0;

        while(!stop) {
            /* Show completion or original buffer */
            if (i < lc.len) {
                linenoiseState saved = *ls;

                (*ls).len = (*ls).pos = strlen(lc.cvec[i]);
                (*ls).buf = lc.cvec[i];
                refreshLine(ls);
                (*ls).len = saved.len;
                (*ls).pos = saved.pos;
                (*ls).buf = saved.buf;
            } else {
                refreshLine(ls);
            }

            nread = read((*ls).ifd,&c,1);
            if (nread <= 0) {
                freeCompletions(&lc);
                return -1;
            }

            switch(c) {
                case 9: /* tab */
                    i = (i+1) % (lc.len+1);
                    if (i == lc.len) linenoiseBeep();
                    break;
                case 27: /* escape */
                    /* Re-show original buffer */
                    if (i < lc.len) refreshLine(ls);
                    stop = 1;
                    break;
                default:
                    /* Update buffer and return */
                    if (i < lc.len) {
                        nwritten = snprintf((*ls).buf,(*ls).buflen,"%s",lc.cvec[i]);
                        (*ls).len = (*ls).pos = nwritten;
                    }
                    stop = 1;
                    break;
            }
        }
    }

    freeCompletions(&lc);
    return c; /* Return last read character */
}


/* Register a callback function to be called for tab-completion. */
void linenoiseSetCompletionCallback(linenoiseCompletionCallback fn) {
    completionCallback = fn;
}

/* Register a hits function to be called to show hits to the user at the
 * right of the prompt. */
void linenoiseSetHintsCallback(linenoiseHintsCallback fn) {
    hintsCallback = fn;
}

/* Register a function to free the hints returned by the hints callback
 * registered with linenoiseSetHintsCallback(). */
void linenoiseSetFreeHintsCallback(linenoiseFreeHintsCallback fn) {
    freeHintsCallback = fn;
}

/* This function is used by the callback function registered by the user
 * in order to add completion options given the input string when the
 * user typed <tab>. See the example.c source code for a very easy to
 * understand example. */
void linenoiseAddCompletion(linenoiseCompletions *lc, const char *str) {
    size_t len = strlen(str);
    char* copied;
    char** cvec;

    copied = cast(char*) malloc(len + 1);
    if (copied == null) return;
    memcpy(copied,str,len+1);
    cvec = cast(char**) realloc((*lc).cvec, (char*).sizeof * ((*lc).len + 1));
    if (cvec == null) {
        free(copied);
        return;
    }
    (*lc).cvec = cvec;
    (*lc).cvec[(*lc).len++] = copied;
}

/* =========================== Line editing ================================= */

/* We define a very simple "append buffer" structure, that is an heap
 * allocated string where we can append to. This is useful in order to
 * write all the escape sequences in a buffer and flush them to the standard
 * output in a single call, to avoid flickering effects. */
struct abuf {
    char *b;
    int len;
}

private void abInit(abuf* ab) {
    (*ab).b = null;
    (*ab).len = 0;
}

private void abAppend(abuf* ab, const char *s, int len) {
    char* buf = cast(char*) realloc((*ab).b, (*ab).len + len);

    if (buf == null) return;
    memcpy(buf + (*ab).len, s, len);
    (*ab).b = buf;
    (*ab).len += len;
}

static void abFree(abuf* ab) {
    free((*ab).b);
}

/* Helper of refreshSingleLine() and refreshMultiLine() to show hints
 * to the right of the prompt. */
void refreshShowHints(abuf *ab, linenoiseState *l, int plen) {
    char[64] seq;
    auto seq_ptr = seq.ptr;
    if (hintsCallback && plen + (*l).len < (*l).cols) {
        int color = -1, bold = 0;
        char *hint = hintsCallback((*l).buf, &color, &bold);
        if (hint) {
            size_t hintlen = strlen(hint);
            size_t hintmaxlen = (*l).cols - (plen + (*l).len);
            if (hintlen > hintmaxlen) hintlen = hintmaxlen;
            if (bold == 1 && color == -1) color = 37;
            if (color != -1 || bold != 0)
                snprintf(seq_ptr,64,toStringz("\033[%d;%d;49m"),bold,color);
            else
                seq[0] = '\0';
            abAppend(ab, seq_ptr, cast(int) strlen(seq_ptr));
            abAppend(ab, hint, cast(int) hintlen);
            if (color != -1 || bold != 0)
                abAppend(ab,toStringz("\033[0m"),4);
            /* Call the function to free the hint returned. */
            if (freeHintsCallback) freeHintsCallback(hint);
        }
    }
}

/* Single line low level line refresh.
 *
 * Rewrite the currently edited line accordingly to the buffer content,
 * cursor position, and number of columns of the terminal. */
private void refreshSingleLine(linenoiseState *l) {
    char[64] seq;
    auto seq_ptr = seq.ptr;
    size_t plen = strlen((*l).prompt);
    int fd = (*l).ofd;
    char *buf = (*l).buf;
    size_t len = (*l).len;
    size_t pos = (*l).pos;
    abuf ab;

    while((plen+pos) >= (*l).cols) {
        buf++;
        len--;
        pos--;
    }
    while (plen+len > (*l).cols) {
        len--;
    }

    abInit(&ab);
    /* Cursor to left edge */
    snprintf(seq_ptr,64,"\r");
    abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    /* Write the prompt and the current buffer content */
    abAppend(&ab,(*l).prompt,cast(int) strlen((*l).prompt));
    if (maskmode == 1) {
        while (len--) abAppend(&ab,"*",1);
    } else {
        abAppend(&ab,buf,cast(int) len);
    }
    /* Show hits if any. */
    refreshShowHints(&ab,l,cast(int) plen);
    /* Erase to right */
    snprintf(seq_ptr,64,"\x1b[0K");
    abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    /* Move cursor to original position. */
    snprintf(seq_ptr,64,"\r\x1b[%dC", cast(int) (pos+plen));
    abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    if (write(fd,ab.b,ab.len) == -1) {} /* Can't recover from write error. */
    abFree(&ab);
}

/* Multi line low level line refresh.
 *
 * Rewrite the currently edited line accordingly to the buffer content,
 * cursor position, and number of columns of the terminal. */
private void refreshMultiLine(linenoiseState *l) {
    char[64] seq;
    auto seq_ptr = seq.ptr;
    int plen = cast(int) strlen((*l).prompt);
    int rows = cast(int) ((plen+(*l).len+(*l).cols-1)/(*l).cols); /* rows used by current buf. */
    int rpos = cast(int) ((plen+(*l).oldpos+(*l).cols)/(*l).cols); /* cursor relative row. */
    int rpos2; /* rpos after refresh. */
    int col; /* colum position, zero-based. */
    int old_rows = cast(int) (*l).maxrows;
    int fd = (*l).ofd, j;
    abuf ab;

    /* Update maxrows if needed. */
    if (rows > (*l).maxrows)
        (*l).maxrows = rows;

    /* First step: clear all the lines used before. To do so start by
     * going to the last row. */
    abInit(&ab);
    if (old_rows-rpos > 0) {
        snprintf(seq_ptr,64,"\x1b[%dB", old_rows - rpos);
        abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    }

    /* Now for every row clear it, go up. */
    for (j = 0; j < old_rows-1; j++) {
        snprintf(seq_ptr,64,"\r\x1b[0K\x1b[1A");
        abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    }

    /* Clean the top line. */
    snprintf(seq_ptr,64,"\r\x1b[0K");
    abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));

    /* Write the prompt and the current buffer content */
    abAppend(&ab,(*l).prompt,cast(int) strlen((*l).prompt));
    if (maskmode == 1) {
        for (uint i = 0; i < (*l).len; i++) abAppend(&ab,"*",1);
    } else {
        abAppend(&ab,(*l).buf,cast(int) (*l).len);
    }

    /* Show hits if any. */
    refreshShowHints(&ab,l,plen);

    /* If we are at the very end of the screen with our prompt, we need to
     * emit a newline and move the prompt to the first column. */
    if ((*l).pos &&
    (*l).pos == (*l).len &&
    ((*l).pos+plen) % (*l).cols == 0)
    {
        abAppend(&ab,"\n",1);
        snprintf(seq_ptr,64,"\r");
        abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
        rows++;
        if (rows > cast(int) (*l).maxrows) (*l).maxrows = rows;
    }

    /* Move cursor to right position. */
    rpos2 = cast(int) ((plen+(*l).pos+(*l).cols)/(*l).cols); /* current cursor relative row. */

    /* Go up till we reach the expected positon. */
    if (rows-rpos2 > 0) {
        snprintf(seq_ptr,64,"\x1b[%dA", rows-rpos2);
        abAppend(&ab,seq_ptr,cast(int) strlen(seq_ptr));
    }

    /* Set column. */
    col = (plen+cast(int) (*l).pos) % cast(int)(*l).cols;
    if (col)
        snprintf(seq_ptr,64,"\r\x1b[%dC", col);
    else
        snprintf(seq_ptr,64,"\r");
    abAppend(&ab,seq_ptr, cast(int) strlen(seq_ptr));

    (*l).oldpos = (*l).pos;

    if (write(fd,ab.b,ab.len) == -1) {} /* Can't recover from write error. */
    abFree(&ab);
}

/* Calls the two low level functions refreshSingleLine() or
 * refreshMultiLine() according to the selected mode. */
private void refreshLine(linenoiseState* l) {
    if (mlmode)
        refreshMultiLine(l);
    else
        refreshSingleLine(l);
}

/* Insert the character 'c' at cursor current position.
 *
 * On error writing to the terminal -1 is returned, otherwise 0. */
int linenoiseEditInsert(linenoiseState* l, char c) {
    if ((*l).len < (*l).buflen) {
        if ((*l).len == (*l).pos) {
            (*l).buf[(*l).pos] = c;
            (*l).pos++;
            (*l).len++;
            (*l).buf[(*l).len] = '\0';
            if ((!mlmode && (*l).plen+(*l).len < (*l).cols && !hintsCallback)) {
                /* Avoid a full update of the line in the
                 * trivial case. */
                char d = (maskmode==1) ? '*' : c;
                if (write((*l).ofd,&d,1) == -1) return -1;
            } else {
                refreshLine(l);
            }
        } else {
            memmove((*l).buf+(*l).pos+1,(*l).buf+(*l).pos,(*l).len-(*l).pos);
            (*l).buf[(*l).pos] = c;
            (*l).len++;
            (*l).pos++;
            (*l).buf[(*l).len] = '\0';
            refreshLine(l);
        }
    }
    return 0;
}

/* Move cursor on the left. */
void linenoiseEditMoveLeft(linenoiseState *l) {
    if ((*l).pos > 0) {
        (*l).pos--;
        refreshLine(l);
    }
}

/* Move cursor on the right. */
void linenoiseEditMoveRight(linenoiseState *l) {
    if ((*l).pos != (*l).len) {
        (*l).pos++;
        refreshLine(l);
    }
}

/* Move cursor to the start of the line. */
void linenoiseEditMoveHome(linenoiseState *l) {
    if ((*l).pos != 0) {
        (*l).pos = 0;
        refreshLine(l);
    }
}

/* Move cursor to the end of the line. */
void linenoiseEditMoveEnd(linenoiseState *l) {
    if ((*l).pos != (*l).len) {
        (*l).pos = (*l).len;
        refreshLine(l);
    }
}

/* Substitute the currently edited line with the next or previous history
 * entry as specified by 'dir'. */
private const int LINENOISE_HISTORY_NEXT = 0;
private const int LINENOISE_HISTORY_PREV = 1;

void linenoiseEditHistoryNext(linenoiseState *l, int dir) {
    if (history_len > 1) {
        /* Update the current history entry before to
         * overwrite it with the next one. */
        free(history[history_len - 1 - (*l).history_index]);
        history[history_len - 1 - (*l).history_index] = strdup((*l).buf);
        /* Show the new entry */
        (*l).history_index += (dir == LINENOISE_HISTORY_PREV) ? 1 : -1;
        if ((*l).history_index < 0) {
            (*l).history_index = 0;
            return;
        } else if ((*l).history_index >= history_len) {
            (*l).history_index = history_len-1;
            return;
        }
        strncpy((*l).buf,history[history_len - 1 - (*l).history_index],(*l).buflen);
        (*l).buf[(*l).buflen-1] = '\0';
        (*l).len = (*l).pos = strlen((*l).buf);
        refreshLine(l);
    }
}

/* Delete the character at the right of the cursor without altering the cursor
 * position. Basically this is what happens with the "Delete" keyboard key. */
void linenoiseEditDelete(linenoiseState *l) {
    if ((*l).len > 0 && (*l).pos < (*l).len) {
        memmove((*l).buf+(*l).pos,(*l).buf+(*l).pos+1,(*l).len-(*l).pos-1);
        (*l).len--;
        (*l).buf[(*l).len] = '\0';
        refreshLine(l);
    }
}

/* Backspace implementation. */
void linenoiseEditBackspace(linenoiseState *l) {
    if ((*l).pos > 0 && (*l).len > 0) {
        memmove((*l).buf+(*l).pos-1,(*l).buf+(*l).pos,(*l).len-(*l).pos);
        (*l).pos--;
        (*l).len--;
        (*l).buf[(*l).len] = '\0';
        refreshLine(l);
    }
}

/* Delete the previosu word, maintaining the cursor at the start of the
 * current word. */
void linenoiseEditDeletePrevWord(linenoiseState *l) {
    size_t old_pos = (*l).pos;
    size_t diff;

    while ((*l).pos > 0 && (*l).buf[(*l).pos-1] == ' ')
        (*l).pos--;
    while ((*l).pos > 0 && (*l).buf[(*l).pos-1] != ' ')
        (*l).pos--;
    diff = old_pos - (*l).pos;
    memmove((*l).buf+(*l).pos,(*l).buf+old_pos,(*l).len-old_pos+1);
    (*l).len -= diff;
    refreshLine(l);
}


/* This function is the core of the line editing capability of linenoise.
 * It expects 'fd' to be already in "raw mode" so that every key pressed
 * will be returned ASAP to read().
 *
 * The resulting string is put into 'buf' when the user type enter, or
 * when ctrl+d is typed.
 *
 * The function returns the length of the current buffer. */
static int linenoiseEdit(int stdin_fd, int stdout_fd, char *buf, size_t buflen, const char *prompt) {

    /* Populate the linenoise state that we pass to functions implementing
     * specific editing functionalities. */
    linenoiseState l = {
    ifd : stdin_fd,
    ofd : stdout_fd,
    buf : buf,
    buflen : buflen,
    prompt : prompt,
    plen : strlen(prompt),
    oldpos : 0,
    pos : 0,
    len : 0,
    cols : getColumns(stdin_fd, stdout_fd),
    maxrows : 0,
    history_index : 0
    };

    /* Buffer starts empty. */
    l.buf[0] = '\0';
    l.buflen--; /* Make sure there is always space for the nulterm */

    /* The latest history entry is always our current buffer, that
     * initially is just an empty string. */
    linenoiseHistoryAdd("");

    if (write(l.ofd,prompt,l.plen) == -1) return -1;
    while(1) {
        char c;
        ssize_t nread;
        char[3] seq;
        auto seq_ptr = seq.ptr;

        nread = read(l.ifd,&c,1);
        if (nread <= 0) return cast(int) l.len;

        /* Only autocomplete when the callback is set. It returns < 0 when
         * there was an error reading from fd. Otherwise it will return the
         * character that should be handled next. */
        if (c == 9 && completionCallback != null) {
            c = cast(char) completeLine(&l);
            /* Return on errors */
            if (c < 0) return cast(int) l.len;
            /* Read next character when 0 */
            if (c == 0) continue;
        }

        switch(c) {
        case KEY_ACTION.ENTER:    /* enter */
            history_len--;
            free(history[history_len]);
            if (mlmode) linenoiseEditMoveEnd(&l);
            if (hintsCallback) {
                /* Force a refresh without hints to leave the previous
                 * line as the user typed it after a newline. */
                linenoiseHintsCallback *hc = &hintsCallback;
                hintsCallback = null;
                refreshLine(&l);
                hintsCallback = *hc;
            }
            return cast(int) l.len;
        case KEY_ACTION.CTRL_C:     /* ctrl-c */
        errno = EAGAIN;
        return -1;
        case KEY_ACTION.BACKSPACE:   /* backspace */
        case 8:     /* ctrl-h */
        linenoiseEditBackspace(&l);
        break;
        case KEY_ACTION.CTRL_D:     /* ctrl-d, remove char at right of cursor, or if the
                            line is empty, act as end-of-file. */
        if (l.len > 0) {
            linenoiseEditDelete(&l);
        } else {
            history_len--;
            free(history[history_len]);
            return -1;
        }
        break;
        case KEY_ACTION.CTRL_T:    /* ctrl-t, swaps current character with previous. */
        if (l.pos > 0 && l.pos < l.len) {
            int aux = buf[l.pos-1];
            buf[l.pos-1] = buf[l.pos];
            buf[l.pos] = cast(char) aux;
            if (l.pos != l.len-1) l.pos++;
            refreshLine(&l);
        }
        break;
        case KEY_ACTION.CTRL_B:     /* ctrl-b */
        linenoiseEditMoveLeft(&l);
        break;
        case KEY_ACTION.CTRL_F:     /* ctrl-f */
        linenoiseEditMoveRight(&l);
        break;
        case KEY_ACTION.CTRL_P:    /* ctrl-p */
        linenoiseEditHistoryNext(&l, LINENOISE_HISTORY_PREV);
        break;
        case KEY_ACTION.CTRL_N:    /* ctrl-n */
        linenoiseEditHistoryNext(&l, LINENOISE_HISTORY_NEXT);
        break;
        case KEY_ACTION.ESC:    /* escape sequence */
        /* Read the next two bytes representing the escape sequence.
             * Use two calls to handle slow terminals returning the two
             * chars at different times. */
        if (read(l.ifd,seq_ptr,1) == -1) break;
        if (read(l.ifd,seq_ptr+1,1) == -1) break;

        /* ESC [ sequences. */
        if (seq[0] == '[') {
            if (seq[1] >= '0' && seq[1] <= '9') {
                /* Extended escape, read additional byte. */
                if (read(l.ifd,seq_ptr+2,1) == -1) break;
                if (seq[2] == '~') {
                    switch(seq[1]) {
                        case '3': /* Delete key. */
                        linenoiseEditDelete(&l);
                        break;
                        default:
                        break;
                    }
                }
            } else {
                switch(seq[1]) {
                    case 'A': /* Up */
                    linenoiseEditHistoryNext(&l, LINENOISE_HISTORY_PREV);
                    break;
                    case 'B': /* Down */
                    linenoiseEditHistoryNext(&l, LINENOISE_HISTORY_NEXT);
                    break;
                    case 'C': /* Right */
                    linenoiseEditMoveRight(&l);
                    break;
                    case 'D': /* Left */
                    linenoiseEditMoveLeft(&l);
                    break;
                    case 'H': /* Home */
                    linenoiseEditMoveHome(&l);
                    break;
                    case 'F': /* End*/
                    linenoiseEditMoveEnd(&l);
                    break;
                    default:
                    break;
                }
            }
        }

        /* ESC O sequences. */
        else if (seq[0] == 'O') {
            switch(seq[1]) {
                case 'H': /* Home */
                linenoiseEditMoveHome(&l);
                break;
                case 'F': /* End*/
                linenoiseEditMoveEnd(&l);
                break;
                default:
                break;
            }
        }
        break;
        default:
        if (linenoiseEditInsert(&l,c)) return -1;
        break;
        case KEY_ACTION.CTRL_U: /* Ctrl+u, delete the whole line. */
        buf[0] = '\0';
        l.pos = l.len = 0;
        refreshLine(&l);
        break;
        case KEY_ACTION.CTRL_K: /* Ctrl+k, delete from current to end of line. */
        buf[l.pos] = '\0';
        l.len = l.pos;
        refreshLine(&l);
        break;
        case KEY_ACTION.CTRL_A: /* Ctrl+a, go to the start of the line */
        linenoiseEditMoveHome(&l);
        break;
        case KEY_ACTION.CTRL_E: /* ctrl+e, go to the end of the line */
        linenoiseEditMoveEnd(&l);
        break;
        case KEY_ACTION.CTRL_L: /* ctrl+l, clear screen */
        linenoiseClearScreen();
        refreshLine(&l);
        break;
        case KEY_ACTION.CTRL_W: /* ctrl+w, delete previous word */
        linenoiseEditDeletePrevWord(&l);
        break;
        }
    }

    // return cast(int) l.len;
}

/* This special mode is used by linenoise in order to print scan codes
 * on screen for debugging / development purposes. It is implemented
 * by the linenoise_example program using the --keycodes option. */
void linenoisePrintKeyCodes() {
    char[4] quit;
    auto quit_ptr = quit.ptr;

    printf("Linenoise key codes debugging mode.\nPress keys to see scan codes. Type 'quit' at any time to exit.\n");
    if (enableRawMode(STDIN_FILENO) == -1) return;
    memset(quit_ptr,' ',4);
    while(1) {
        char c;
        ssize_t nread;

        nread = read(STDIN_FILENO,&c,1);
        if (nread <= 0) continue;
        memmove(quit_ptr,quit_ptr + 1,quit.sizeof - 1); /* shift string to left. */
        quit[quit.sizeof - 1] = c; /* Insert current char on the right. */
        if (memcmp(quit_ptr,toStringz("quit"),quit.sizeof) == 0) break;

        printf("'%c' %02x (%d) (type quit to exit)\n",
        isprint(c) ? c : '?', cast(int) c, cast(int) c);
        printf("\r"); /* Go left edge manually, we are in raw mode. */
        fflush(stdout);
    }
    disableRawMode(STDIN_FILENO);
}

/* This function calls the line editing function linenoiseEdit() using
 * the STDIN file descriptor set in raw mode. */
static int linenoiseRaw(char *buf, size_t buflen, const char *prompt) {
    int count;

    if (buflen == 0) {
        errno = EINVAL;
        return -1;
    }

    if (enableRawMode(STDIN_FILENO) == -1) return -1;
    count = linenoiseEdit(STDIN_FILENO, STDOUT_FILENO, buf, buflen, prompt);
    disableRawMode(STDIN_FILENO);
    printf("\n");
    return count;
}

/* This function is called when linenoise() is called with the standard
 * input file descriptor not attached to a TTY. So for example when the
 * program using linenoise is called in pipe or with a file redirected
 * to its standard input. In this case, we want to be able to return the
 * line regardless of its length (by default we are limited to 4k). */
private char* linenoiseNoTTY() {
    char *line = null;
    size_t len = 0;
    size_t maxlen = 0;

    while(1) {
        if (len == maxlen) {
            if (maxlen == 0) maxlen = 16;
            maxlen *= 2;
            char *oldval = line;
            line = cast(char*) realloc(line,maxlen);
            if (line == null) {
                if (oldval) free(oldval);
                return null;
            }
        }
        int c = fgetc(stdin);
        if (c == EOF || c == '\n') {
            if (c == EOF && len == 0) {
                free(line);
                return null;
            } else {
                line[len] = '\0';
                return line;
            }
        } else {
            line[len] = cast(char) c;
            len++;
        }
    }
}


/* The high level function that is the main API of the linenoise library.
 * This function checks if the terminal has basic capabilities, just checking
 * for a blacklist of stupid terminals, and later either calls the line
 * editing function or uses dummy fgets() so that you will be able to type
 * something even in the most desperate of the conditions. */
char* linenoise(const char* prompt) {
    char[LINENOISE_MAX_LINE] buf;
    auto buf_ptr = buf.ptr;
    int count;

    if (!isatty(STDIN_FILENO)) {
        /* Not a tty: read from file / pipe. In this mode we don't want any
         * limit to the line size, so we call a function to handle that. */
        return linenoiseNoTTY();
    } else if (isUnsupportedTerm()) {
        size_t len;

        printf("%s",prompt);
        fflush(stdout);
        if (fgets(buf_ptr,LINENOISE_MAX_LINE,stdin) == null) return null;
        len = strlen(buf_ptr);
        while(len && (buf[len-1] == '\n' || buf[len-1] == '\r')) {
            len--;
            buf[len] = '\0';
        }
        return strdup(buf_ptr);
    } else {
        count = linenoiseRaw(buf_ptr,LINENOISE_MAX_LINE,prompt);
        if (count == -1) return null;
        return strdup(buf_ptr);
    }
}

/* This is just a wrapper the user may want to call in order to make sure
 * the linenoise returned buffer is freed with the same allocator it was
 * created with. Useful when the main program is using an alternative
 * allocator. */
void linenoiseFree(void *ptr) {
    free(ptr);
}

/* ================================ History ================================= */

/* Free the history, but does not reset it. Only used when we have to
 * exit() to avoid memory leaks are reported by valgrind & co. */
private void freeHistory() {
    if (history) {
        int j;

        for (j = 0; j < history_len; j++)
            free(history[j]);
        free(history);
    }
}

/* At exit we'll try to fix the terminal to the initial conditions. */
private void linenoiseAtExit() {
    disableRawMode(STDIN_FILENO);
    freeHistory();
}

/* This is the API call to add a new entry in the linenoise history.
 * It uses a fixed array of char pointers that are shifted (memmoved)
 * when the history max length is reached in order to remove the older
 * entry and make room for the new one, so it is not exactly suitable for huge
 * histories, but will work well for a few hundred of entries.
 *
 * Using a circular buffer is smarter, but a bit more complex to handle. */
int linenoiseHistoryAdd(const char *line) {
    char *linecopy;

    if (history_max_len == 0) return 0;

    /* Initialization on first call. */
    if (history == null) {
        history = malloc((char*).sizeof * history_max_len);
        if (history == null) return 0;
        memset(history,0,((char*).sizeof * history_max_len));
    }

    /* Don't add duplicated lines. */
    if (history_len && !strcmp(history[history_len-1], line)) return 0;

    /* Add an heap allocated copy of the line in the history.
     * If we reached the max length, remove the older line. */
    linecopy = strdup(line);
    if (!linecopy) return 0;
    if (history_len == history_max_len) {
        free(history[0]);
        memmove(history,history+1,(char*).sizeof * (history_max_len-1));
        history_len--;
    }
    history[history_len] = linecopy;
    history_len++;
    return 1;
}

/* Set the maximum length for the history. This function can be called even
 * if there is already some history, the function will make sure to retain
 * just the latest 'len' elements if the new history length value is smaller
 * than the amount of items already inside the history. */
int linenoiseHistorySetMaxLen(int len) {
    char** newhis;

    if (len < 1) return 0;
    if (history) {
        int tocopy = history_len;

        newhis = malloc((char*).sizeof * len);
        if (newhis == null) return 0;

        /* If we can't copy everything, free the elements we'll not use. */
        if (len < tocopy) {
            int j;

            for (j = 0; j < tocopy-len; j++) free(history[j]);
            tocopy = len;
        }
        memset(newhis,0,(char*).sizeof * len);
        memcpy(newhis,history+(history_len-tocopy), (char*).sizeof * tocopy);
        free(history);
        history = newhis;
    }
    history_max_len = len;
    if (history_len > history_max_len)
        history_len = history_max_len;
    return 1;
}

/* Save the history in the specified file. On success 0 is returned
 * otherwise -1 is returned. */
int linenoiseHistorySave(const char *filename) {
    mode_t old_umask = umask(S_IXUSR|S_IRWXG|S_IRWXO);
    FILE *fp;
    int j;

    fp = fopen(filename,"w");
    umask(old_umask);
    if (fp == null) return -1;
    chmod(filename,S_IRUSR|S_IWUSR);
    for (j = 0; j < history_len; j++)
        fprintf(fp,"%s\n",history[j]);
    fclose(fp);
    return 0;
}

/* Load the history from the specified file. If the file does not exist
 * zero is returned and no operation is performed.
 *
 * If the file exists and the operation succeeded 0 is returned, otherwise
 * on error -1 is returned. */
int linenoiseHistoryLoad(const char *filename) {
    FILE *fp = fopen(filename,"r");
    char[LINENOISE_MAX_LINE] buf;
    auto buf_ptr = buf.ptr;

    if (fp == null) return -1;

    while (fgets(buf,LINENOISE_MAX_LINE,fp) != null) {
        char *p;

        p = strchr(buf,'\r');
        if (!p) p = strchr(buf,'\n');
        if (p) *p = '\0';
        linenoiseHistoryAdd(buf);
    }
    fclose(fp);
    return 0;
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
