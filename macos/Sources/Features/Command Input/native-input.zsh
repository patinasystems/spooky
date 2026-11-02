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
typeset -gA _patina_native_completion_seen
typeset -gi _patina_native_completion_available=0 _patina_native_completion_fd=0
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
    _patina_native_completion_start

    # A starts the header on a fresh line; the LF reserves exactly one row.
    # B may repeat during ZLE redisplay. The block identity remains unchanged.
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;A;aid='"$_patina_native_block_id"$'\a\n'
    PS1=$'%{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    PS2=$'%{\e]133;P;k=s\a%}> %{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    return 0
}

_patina_native_preexec() {
    _patina_native_completion_stop
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
    _patina_native_completion_stop
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

# Completion uses a private ZLE, forked at each primary prompt. zpty inherits
# this shell's cwd, variables, functions, aliases and compdefs; it does not run
# another .zshrc. Forking in precmd is important: vared cannot start recursively
# from an active ZLE widget. The real terminal buffer is never borrowed or
# redrawn, including for long/multiline drafts. Worker output is only drained.
#
# completion-request: generation LF, UUID LF, UTF-8 caret byte offset LF, draft.
# completions/<UUID> is published by one atomic directory rename. Files:
# generation, identifier, status (ok/rejected), reason, count, truncated (0/1),
# items/<1..count>/buffer (exact resulting UTF-8 draft), and cursor (byte offset).
# The app binds UUID to its draft revision and discards obsolete responses.

_patina_native_completion_initialize() {
    # This starter shell deliberately loads only the system completion library.
    # No user rc, completion dump, or site-function autoload path is consulted.
    fpath=(/usr/share/zsh/$ZSH_VERSION/functions)
    builtin autoload -Uz compinit
    compinit -i -D &&
        builtin zmodload zsh/zpty &&
        builtin zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm &&
        builtin zf_mkdir -p "$_patina_native_dir/completions" &&
        _patina_native_completion_available=1
    return 0
}

_patina_native_completion_noop() { return 0 }

_patina_native_completion_stop() {
    if (( _patina_native_completion_fd )); then
        builtin zle -F $_patina_native_completion_fd 2>/dev/null
        _patina_native_completion_fd=0
    fi
    if (( _patina_native_completion_available )); then
        builtin zpty -d _patina_native_completion 2>/dev/null
        builtin zf_rm -f "$_patina_native_dir/completion-active" 2>/dev/null
        builtin zf_rm -f "$_patina_native_dir"/completion-worker-request.*(N) 2>/dev/null
        # All children belong to this retired prompt, including late responses
        # whose native request was cancelled before the worker published them.
        builtin zf_rm -rf "$_patina_native_dir/completions"/*(DN) 2>/dev/null
    fi
    return 0
}

_patina_native_completion_drain() {
    builtin zpty -r _patina_native_completion >/dev/null 2>&1
    if (( $? == 2 )); then
        builtin zle -F "$1" 2>/dev/null
        _patina_native_completion_fd=0
    fi
    return 0
}

_patina_native_completion_start() {
    _patina_native_completion_stop
    # Old requests are rejected by generation; UUID replay tracking only needs
    # to survive within this primary prompt.
    _patina_native_completion_seen=()
    (( _patina_native_completion_available )) || return 0
    # The command is a fixed function name. No draft/request text is passed to
    # zpty's command parser (which otherwise evaluates its string arguments).
    if builtin zpty -b _patina_native_completion _patina_native_completion_worker; then
        _patina_native_completion_fd=$REPLY
        builtin zle -F $_patina_native_completion_fd _patina_native_completion_drain
    fi
    return 0
}

_patina_native_completion_worker() {
    # The worker must never publish lifecycle/block events for the real shell.
    precmd_functions=()
    preexec_functions=()
    zshexit_functions=()
    builtin zle -N zle-line-init _patina_native_completion_noop
    builtin zle -N zle-line-pre-redraw _patina_native_completion_noop
    builtin zle -N zle-line-finish _patina_native_completion_noop
    builtin bindkey -e
    builtin bindkey $'\e[99;2~' _patina_native_completion_worker_widget
    if (( _patina_native_tty > 2 )); then
        builtin exec {_patina_native_tty}>&-
    fi
    local working=''
    builtin vared -i _patina_native_completion_noop \
        -f _patina_native_completion_noop working
}

# Populate dynamically scoped generation/identifier/payload/caret/character_caret
# and reason. Read only a finite regular file; no eval or shell expansion.
_patina_native_completion_read() {
    local descriptor REPLY
    local -A metadata
    if ! builtin zmodload zsh/stat ||
       ! builtin zstat -H metadata "$1" || (( metadata[size] > 1048846 )); then
        reason=oversized-request
        return 1
    fi
    {
        builtin exec {descriptor}< "$1" || return 1
        if ! IFS= builtin read -r -u $descriptor generation ||
           ! IFS= builtin read -r -u $descriptor identifier ||
           ! IFS= builtin read -r -u $descriptor caret; then
            reason=malformed-request
            return 1
        fi
        if [[ -z $identifier || ${#identifier} -gt 128 ||
              $identifier == *[^a-zA-Z0-9-]* ]]; then
            identifier='-'
            reason=malformed-identifier
            return 1
        fi
        if [[ -z $caret || ${#caret} -gt 7 || $caret == *[^0-9]* ]]; then
            reason=malformed-caret
            return 1
        fi
        if IFS= builtin read -r -d '' -u $descriptor payload; then
            reason=nul-in-draft
            return 1
        fi
        _patina_native_byte_count "$payload"
        if (( REPLY > 1048576 )); then
            reason=oversized-draft
            return 1
        elif (( 10#$caret > REPLY )); then
            reason=invalid-caret
            return 1
        fi
        if ! command /usr/bin/iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1; then
            reason=invalid-utf8
            return 1
        fi

        # Standard compsys can execute command substitutions while expanding a
        # path. Reject dynamic syntax even inside quotes/escapes in this prototype.
        # Basic $NAME completion is supported; braced/parenthesized expansion,
        # process substitution, backticks and executable glob qualifiers are not.
        if [[ $payload == *'`'* || $payload == *'('* || $payload == *'{'* ||
              $payload == *\$\'* ]]; then
            reason=unsupported-dynamic-syntax
            return 1
        fi
        # ZLE CURSOR counts Unicode characters, while the transport uses bytes.
        # Binary search also rejects byte offsets in the middle of a scalar.
        local -i low=0 high=${#payload} middle bytes wanted=10#$caret
        character_caret=-1
        while (( low <= high )); do
            middle=$(( (low + high) / 2 ))
            _patina_native_byte_count "${payload[1,middle]}"
            bytes=$REPLY
            if (( bytes == wanted )); then
                character_caret=$middle
                break
            elif (( bytes < wanted )); then
                low=$(( middle + 1 ))
            else
                high=$(( middle - 1 ))
            fi
        done
        if (( character_caret < 0 )); then
            reason=invalid-caret
            return 1
        fi
    } always {
        [[ -n $descriptor ]] && builtin exec {descriptor}<&-
    }
}

_patina_native_completion_reject() {
    local destination="$_patina_native_dir/completions/$identifier"
    local staging="$_patina_native_dir/completions/.pending-$identifier"
    # Successful/previously rejected responses are immutable, even on replay.
    [[ -e $destination ]] && return 0
    builtin zf_mkdir -p "$staging" || return 1
    builtin print -rn -- "$generation" > "$staging/generation"
    builtin print -rn -- "$identifier" > "$staging/identifier"
    builtin print -rn -- rejected > "$staging/status"
    builtin print -rn -- "$reason" > "$staging/reason"
    builtin print -rn -- 0 > "$staging/count"
    builtin print -rn -- 0 > "$staging/truncated"
    builtin zf_mv "$staging" "$destination"
}

_patina_native_complete() {
    builtin emulate -L zsh
    local LC_ALL=en_US.UTF-8
    local request="$_patina_native_dir/completion-request"
    local consumed="$_patina_native_dir/completion-consumed.$$"
    [[ -f $request && ! -L $request ]] || return 0
    (( _patina_native_completion_available )) || return 0
    builtin zf_mv -f "$request" "$consumed" || return 1
    local generation identifier='-' payload caret reason
    local -i character_caret
    {
        if _patina_native_completion_read "$consumed"; then
            if [[ -n ${_patina_native_completion_seen[$identifier]-} ]]; then
                # Also leave an in-flight response alone. Publishing a second
                # directory with the same UUID could race its first writer.
                return 0
            elif [[ $generation != $_patina_native_generation ]]; then
                reason=stale-generation
            elif [[ $CONTEXT != start ]]; then
                reason=not-primary-prompt
            elif [[ -n $BUFFER ]]; then
                reason=nonempty-buffer
            elif (( ! _patina_native_completion_fd )); then
                reason=worker-unavailable
            fi
        fi
        _patina_native_completion_seen[$identifier]=1
        if [[ -n $reason ]]; then
            _patina_native_completion_reject
            return 0
        fi
        builtin zf_mv -f "$consumed" "$_patina_native_dir/completion-active" || return 1
        builtin zpty -w -n _patina_native_completion $'\e[99;2~'
    } always {
        builtin zf_rm -f "$consumed"
    }
}

_patina_native_completion_generate() {
    # vared otherwise completes a variable's value rather than a command line.
    compstate[vared]=''
    _main_complete
    _patina_completion_matches=$compstate[nmatches]
    compstate[insert]='menu:1'
    compstate[list]=''
    unset MENUSELECT
}

_patina_native_completion_worker_widget() {
    builtin emulate -L zsh
    local LC_ALL=en_US.UTF-8
    local generation identifier='-' payload caret reason REPLY
    local -i character_caret
    local active="$_patina_native_dir/completion-active"
    local request="$_patina_native_dir/completion-worker-request.$_patina_native_block_id"
    [[ -f $active && ! -L $active ]] || return 0
    # Claim by rename before reading. A newer request can then replace active
    # without the old reader deleting it after finishing its own payload.
    builtin zf_mv -f "$active" "$request" || return 0
    if ! _patina_native_completion_read "$request"; then
        _patina_native_completion_reject
        return 0
    fi
    builtin zf_rm -f "$request"
    local destination="$_patina_native_dir/completions/$identifier"
    local staging="$_patina_native_dir/completions/.pending-$identifier"
    [[ -e $destination ]] && return 0
    builtin zf_mkdir -p "$staging/items" || return 1
    local -i _patina_completion_matches=0 index count=0 total_bytes=0 truncated=0 bytes
    local -A seen
    {
        BUFFER=$payload
        CURSOR=$character_caret
        builtin zle _patina_native_completion_generate_widget
        for (( index=1; index<=_patina_completion_matches; ++index )); do
            # Hidden/duplicate display matches must not make enumeration unbounded.
            if (( index > 400 )); then
                truncated=1
                break
            fi
            if (( index > 1 )); then
                # Explicit -n is required: without it repeated calls can reuse
                # the same candidate instead of advancing the menu.
                builtin zle .menu-complete -n 1
            fi
            [[ -n ${seen[$BUFFER]-} ]] && continue
            seen[$BUFFER]=1
            _patina_native_byte_count "$BUFFER"
            bytes=$REPLY
            if (( count >= 200 || bytes > 1048576 || total_bytes + bytes > 8388608 )); then
                truncated=1
                break
            fi
            (( ++count, total_bytes += bytes ))
            builtin zf_mkdir "$staging/items/$count" || return 1
            builtin print -rn -- "$BUFFER" > "$staging/items/$count/buffer"
            _patina_native_byte_count "$LBUFFER"
            builtin print -rn -- "$REPLY" > "$staging/items/$count/cursor"
        done
        builtin print -rn -- "$generation" > "$staging/generation"
        builtin print -rn -- "$identifier" > "$staging/identifier"
        builtin print -rn -- ok > "$staging/status"
        builtin print -rn -- '' > "$staging/reason"
        builtin print -rn -- "$count" > "$staging/count"
        builtin print -rn -- "$truncated" > "$staging/truncated"
        builtin zf_mv "$staging" "$destination"
    } always {
        BUFFER=''
        CURSOR=0
        builtin zf_rm -rf "$staging"
    }
}

_patina_native_completion_initialize

builtin zle -N _patina_native_submit
builtin zle -N _patina_native_complete
builtin zle -N _patina_native_completion_worker_widget
builtin zle -C _patina_native_completion_generate_widget menu-complete _patina_native_completion_generate
builtin zle -N zle-line-init _patina_native_line_init
builtin zle -N zle-line-pre-redraw _patina_native_redraw
builtin zle -N zle-line-finish _patina_native_line_finish
# The starter shell uses emacs mode; also bind vi maps for explicit user toggles.
builtin bindkey -M emacs $'\e[99;1~' _patina_native_submit
builtin bindkey -M viins $'\e[99;1~' _patina_native_submit
builtin bindkey -M vicmd $'\e[99;1~' _patina_native_submit
builtin bindkey -M emacs $'\e[99;2~' _patina_native_complete
builtin bindkey -M viins $'\e[99;2~' _patina_native_complete
builtin bindkey -M vicmd $'\e[99;2~' _patina_native_complete
builtin typeset -ga precmd_functions preexec_functions zshexit_functions
precmd_functions+=(_patina_native_precmd)
preexec_functions+=(_patina_native_preexec)
zshexit_functions+=(_patina_native_exit)
_patina_native_publish running bootstrap
