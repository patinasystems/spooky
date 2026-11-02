# Native command input prototype. Loaded only by the isolated starter shell.
#
# The app owns a private (0700), per-shell PATINA_NATIVE_INPUT_DIR. It atomically
# publishes `request`: generation LF, request UUID LF, then the UTF-8 draft.
# A normal ZLE key widget, bound to ESC [ 99 ; 1 ~, consumes it exactly once.
# This is deliberately not an adapter for arbitrary user startup files/plugins.

[[ -o interactive && -n $PATINA_NATIVE_INPUT_DIR &&
   $PATINA_NATIVE_INPUT_DIR == /* && -d $PATINA_NATIVE_INPUT_DIR &&
   ! -L $PATINA_NATIVE_INPUT_DIR ]] || return 0
(( ${+_patina_native_loaded} )) && return 0

typeset -g _patina_native_loaded=1
typeset -g _patina_native_dir=$PATINA_NATIVE_INPUT_DIR
unset PATINA_NATIVE_INPUT_DIR
typeset -gi _patina_native_counter=0
typeset -g _patina_native_generation="$$-0"
typeset -g _patina_native_last_state=''
typeset -gA _patina_native_seen
typeset -gi _patina_native_block_counter=0 _patina_native_input_recorded=0
typeset -g _patina_native_block_id=''
typeset -gi _patina_native_tty=1
builtin zmodload zsh/datetime
{
    builtin zmodload zsh/system &&
        builtin sysopen -o cloexec -wu _patina_native_tty -- /dev/tty
} 2>/dev/null || _patina_native_tty=1

# One native-owned prompt, with no duplicate hostname or right-prompt display.
# The primary prompt's single blank header row is emitted before ZLE starts;
# PS1 itself contains only a nonprinting input-boundary marker.
PS1=''
PS2='> '
RPS1=''
RPS2=''

_patina_native_metadata() {
    builtin emulate -L zsh
    [[ -n $_patina_native_block_id ]] || return 1
    local destination="$_patina_native_dir/blocks/$_patina_native_block_id/$1"
    local temporary="$destination.tmp.$$"
    builtin print -rn -- "$2" > "$temporary" &&
        command /bin/mv -f "$temporary" "$destination"
}

_patina_native_record_input() {
    (( _patina_native_input_recorded )) && return 0
    _patina_native_metadata input "$1" || return 1
    _patina_native_metadata status accepted || return 1
    _patina_native_input_recorded=1
}

_patina_native_finish_block() {
    local result=$1
    [[ -n $_patina_native_block_id ]] || return 0
    _patina_native_metadata exit-status "$result"
    _patina_native_metadata finished-wall "$EPOCHREALTIME"
    _patina_native_metadata status completed
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;D;'"$result"';aid='"$_patina_native_block_id"$'\a'
}

_patina_native_precmd() {
    # Preserve the foreground command's status before touching files or git.
    local result=$?
    _patina_native_finish_block "$result"
    (( ++_patina_native_block_counter ))
    _patina_native_block_id="$$-$_patina_native_block_counter"
    _patina_native_input_recorded=0
    command /bin/mkdir -p "$_patina_native_dir/blocks/$_patina_native_block_id"
    _patina_native_metadata cwd "$PWD"
    local branch
    branch=$(command /usr/bin/git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=''
    _patina_native_metadata branch "$branch"
    _patina_native_metadata status editing

    # A starts the header on a fresh line; the LF reserves exactly one row.
    # B may repeat during ZLE redisplay. The block identity remains unchanged.
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;A;aid='"$_patina_native_block_id"$'\a\n'
    PS1=$'%{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    PS2=$'%{\e]133;P;k=s\a%}> %{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    return 0
}

_patina_native_preexec() {
    # Keep the original accepted native buffer immutable. In a continuation,
    # preexec's typed command includes the additional terminal-entered lines.
    _patina_native_record_input "$1"
    _patina_native_metadata executed-input "$1"
    _patina_native_metadata started-wall "$EPOCHREALTIME"
    _patina_native_metadata status running
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;C;aid='"$_patina_native_block_id"$'\a'
    return 0
}

_patina_native_exit() {
    local result=$?
    _patina_native_finish_block "$result"
    _patina_native_publish exited end
    return 0
}

_patina_native_publish() {
    builtin emulate -L zsh
    local value="$1"$'\t'"$_patina_native_generation"$'\t'"$2"$'\t'"$_patina_native_block_id"
    [[ $value == $_patina_native_last_state ]] && return 0
    local temporary="$_patina_native_dir/state.tmp.$$"
    builtin print -r -- "$value" > "$temporary" &&
        command /bin/mv -f "$temporary" "$_patina_native_dir/state" &&
        _patina_native_last_state=$value
}

_patina_native_receipt() {
    builtin emulate -L zsh
    local value="$1"$'\t'"$2"
    [[ -n $3 ]] && value+=$'\t'"$3"
    local temporary="$_patina_native_dir/receipt.tmp.$$"
    builtin print -r -- "$value" > "$temporary" &&
        command /bin/mv -f "$temporary" "$_patina_native_dir/receipt"
}

_patina_native_line_init() {
    (( ++_patina_native_counter ))
    _patina_native_generation="$$-$_patina_native_counter"
    _patina_native_redraw
}

_patina_native_redraw() {
    if [[ $CONTEXT != start ]]; then
        _patina_native_publish terminal "$CONTEXT"
    elif [[ -n $BUFFER ]]; then
        _patina_native_publish terminal start
    else
        _patina_native_publish ready start
    fi
}

_patina_native_line_finish() {
    if [[ $CONTEXT == start ]]; then
        _patina_native_record_input "$BUFFER"
    fi
    _patina_native_publish running "$CONTEXT"
}

_patina_native_byte_count() {
    local LC_ALL=C
    REPLY=${#1}
}

_patina_native_submit() {
    builtin emulate -L zsh
    local request="$_patina_native_dir/request"
    local consumed="$_patina_native_dir/consumed.$$"
    # A delayed duplicate trigger must not erase a receipt the app has yet to see.
    [[ -f $request && ! -L $request ]] || return 0
    command /bin/mv -f "$request" "$consumed" || return 1

    local generation identifier payload descriptor reason REPLY
    local -A metadata
    {
        if ! builtin zmodload zsh/stat ||
           ! builtin zstat -H metadata "$consumed" ||
           (( metadata[size] > 1048834 )); then
            _patina_native_receipt rejected - oversized-request
            return 1
        fi
        builtin exec {descriptor}< "$consumed" || return 1
        if ! IFS= builtin read -r -u $descriptor generation ||
           ! IFS= builtin read -r -u $descriptor identifier; then
            _patina_native_receipt rejected - malformed-request
            return 1
        fi
        if [[ -z $identifier || ${#identifier} -gt 128 ||
              $identifier == *[^a-zA-Z0-9-]* ]]; then
            _patina_native_receipt rejected - malformed-identifier
            return 1
        fi
        # EOF is expected. read -d '' returns success only for a forbidden NUL.
        if IFS= builtin read -r -d '' -u $descriptor payload; then
            _patina_native_receipt rejected "$identifier" nul-in-draft
            return 1
        fi
        _patina_native_byte_count "$payload"
        if (( REPLY > 1048576 )); then
            reason=oversized-draft
        elif [[ -n ${_patina_native_seen[$identifier]-} ]]; then
            reason=duplicate-request
        elif [[ $generation != $_patina_native_generation ]]; then
            reason=stale-generation
        elif [[ $CONTEXT != start ]]; then
            reason=not-primary-prompt
        elif [[ -n $BUFFER ]]; then
            reason=nonempty-buffer
        fi
        _patina_native_seen[$identifier]=1
        if [[ -n $reason ]]; then
            _patina_native_receipt rejected "$identifier" "$reason"
            return 1
        fi

        if ! _patina_native_record_input "$payload"; then
            _patina_native_receipt rejected "$identifier" metadata-write-failed
            return 1
        fi
        BUFFER=$payload
        CURSOR=${#BUFFER}
        # Acceptance means ZLE owns the draft, not that it parsed/executed it.
        # Incomplete syntax can legitimately enter a continuation prompt.
        if ! _patina_native_receipt accepted "$identifier"; then
            BUFFER=''
            CURSOR=0
            return 1
        fi
        _patina_native_publish running start
        builtin zle .accept-line
    } always {
        [[ -n $descriptor ]] && builtin exec {descriptor}<&-
        command /bin/rm -f "$consumed"
    }
}

builtin zle -N _patina_native_submit
builtin zle -N zle-line-init _patina_native_line_init
builtin zle -N zle-line-pre-redraw _patina_native_redraw
builtin zle -N zle-line-finish _patina_native_line_finish
# The starter shell uses emacs mode; also bind vi maps for explicit user toggles.
builtin bindkey -M emacs $'\e[99;1~' _patina_native_submit
builtin bindkey -M viins $'\e[99;1~' _patina_native_submit
builtin bindkey -M vicmd $'\e[99;1~' _patina_native_submit
builtin typeset -ga precmd_functions preexec_functions zshexit_functions
precmd_functions+=(_patina_native_precmd)
preexec_functions+=(_patina_native_preexec)
zshexit_functions+=(_patina_native_exit)
_patina_native_publish running bootstrap
