# Native command input integration, loaded after the user's zsh startup files.
#
# The app owns a private (0700), per-shell PATINA_NATIVE_INPUT_DIR. It atomically
# publishes `request`: generation LF, request UUID LF, then the UTF-8 draft.
# A normal ZLE key widget, bound to ESC [ 99 ; 1 ~, consumes it exactly once.
# User configuration owns the environment, history, completion system and main
# keymap. Native block mode owns visible prompt text while ZLE is editing.

# Source the definitions with aliases disabled and stable parsing options, then
# restore every caller option. Quoting this small loader also protects it from
# aliases defined by .zshrc before the rest of the file is parsed.
if [[ ${_patina_native_loading-} != 1 ]]; then
    () {
        'builtin' 'emulate' -L zsh -o no_aliases -o no_warn_create_global
        'builtin' 'local' _patina_native_loading=1
        'builtin' 'source' -- "${(%):-%x}"
    }
    'builtin' 'return' "$?"
fi

[[ -o interactive && -n $PATINA_NATIVE_INPUT_DIR &&
   $PATINA_NATIVE_INPUT_DIR == /* && -d $PATINA_NATIVE_INPUT_DIR &&
   ! -L $PATINA_NATIVE_INPUT_DIR ]] || return 0
(( ${+_patina_native_loaded} )) && return 0
# A user may deliberately remove the system functions from fpath. Without the
# hook helper we cannot preserve their ZLE widgets; leave the ordinary shell
# intact rather than taking over its prompt with an incomplete integration.
if (( ! ${+functions[add-zle-hook-widget]} )) ||
   [[ ${functions[add-zle-hook-widget]} == 'builtin autoload -X'* ]]; then
    builtin autoload -Uz +X add-zle-hook-widget 2>/dev/null || return 1
fi

builtin typeset -g _patina_native_loaded=1
builtin typeset -g _patina_native_dir=$PATINA_NATIVE_INPUT_DIR
builtin unset PATINA_NATIVE_INPUT_DIR
builtin typeset -gi _patina_native_counter=0
builtin typeset -g _patina_native_generation="$$-0"
builtin typeset -g _patina_native_last_state=''
builtin typeset -gA _patina_native_seen
builtin typeset -gA _patina_native_completion_seen
builtin typeset -gA _patina_native_completion_options
builtin typeset -gi _patina_native_completion_available=0 _patina_native_completion_fd=0
builtin typeset -gi _patina_native_block_counter=0 _patina_native_input_recorded=0
builtin typeset -g _patina_native_block_id=''
builtin typeset -gi _patina_native_tty=1
builtin zmodload zsh/datetime
{
    builtin zmodload zsh/system &&
        builtin sysopen -o cloexec -wu _patina_native_tty -- /dev/tty
} 2>/dev/null || _patina_native_tty=1

builtin typeset -g _patina_native_saved_ps1=$PS1 _patina_native_saved_ps2=$PS2
builtin typeset -g _patina_native_saved_rps1=$RPS1 _patina_native_saved_rps2=$RPS2
builtin typeset -g _patina_native_marked_ps1='' _patina_native_marked_ps2=''
builtin typeset -g _patina_native_block_cwd=''
builtin typeset -gi _patina_native_prompt_active=0

_patina_native_restore_prompt() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    (( _patina_native_prompt_active )) || return 0
    [[ $PS1 == $_patina_native_marked_ps1 ]] && PS1=$_patina_native_saved_ps1
    [[ $PS2 == $_patina_native_marked_ps2 ]] && PS2=$_patina_native_saved_ps2
    [[ -z $RPS1 ]] && RPS1=$_patina_native_saved_rps1
    [[ -z $RPS2 ]] && RPS2=$_patina_native_saved_rps2
    _patina_native_prompt_active=0
    return 0
}

_patina_native_apply_prompt() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    _patina_native_restore_prompt
    _patina_native_saved_ps1=$PS1
    _patina_native_saved_ps2=$PS2
    _patina_native_saved_rps1=$RPS1
    _patina_native_saved_rps2=$RPS2
    _patina_native_marked_ps1=$'%{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    _patina_native_marked_ps2=$'%{\e]133;P;k=s\a%}'"$PS2"$'%{\e]133;B;aid='"$_patina_native_block_id"$'\a%}'
    PS1=$_patina_native_marked_ps1
    PS2=$_patina_native_marked_ps2
    RPS1=''
    RPS2=''
    _patina_native_prompt_active=1
}

# Same-directory moves remain atomic renames. Use zsh's in-process file
# builtins for the per-submit publications; retain the external-tool fallback
# for zsh installations without the optional files module.
if builtin zmodload -F zsh/files b:zf_mv b:zf_mkdir b:zf_rm 2>/dev/null; then
    _patina_native_move() { builtin zf_mv "$@" }
    _patina_native_mkdir() { builtin zf_mkdir "$@" }
    _patina_native_remove() { builtin zf_rm "$@" }
else
    _patina_native_move() { command /bin/mv "$@" }
    _patina_native_mkdir() { command /bin/mkdir "$@" }
    _patina_native_remove() { command /bin/rm "$@" }
fi

_patina_native_metadata() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    [[ -n $_patina_native_block_id ]] || return 1
    builtin local destination="$_patina_native_dir/blocks/$_patina_native_block_id/$1"
    builtin local temporary="$destination.tmp.$$"
    builtin print -rn -- "$2" > "$temporary" &&
        _patina_native_move -f "$temporary" "$destination"
}

_patina_native_record_input() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    (( _patina_native_input_recorded )) && return 0
    _patina_native_metadata input "$1" || return 1
    _patina_native_metadata status accepted || return 1
    _patina_native_input_recorded=1
}

_patina_native_finish_block() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local result=$1
    [[ -n $_patina_native_block_id ]] || return 0
    _patina_native_metadata exit-status "$result"
    _patina_native_metadata finished-wall "$EPOCHREALTIME"
    _patina_native_metadata status completed
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;D;'"$result"';aid='"$_patina_native_block_id"$'\a'
}

_patina_native_precmd() {
    # Preserve the foreground command's status before touching files or git.
    builtin local result=$?
    # Capture user options before entering the implementation's temporary
    # parsing settings. Completion restores the relevant options in its worker.
    if builtin zle; then
        _patina_native_apply_prompt
        return 0
    fi
    if (( ${+_patina_native_initial_options} )); then
        _patina_native_completion_options=("${(@kv)_patina_native_initial_options[@]}")
    else
        _patina_native_completion_options=("${(@kv)options[@]}")
    fi
    _patina_native_prepare_prompt "$result"
    _patina_native_completion_start
    return 0
}

_patina_native_prepare_prompt() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local result=$1
    _patina_native_finish_block "$result"
    (( ++_patina_native_block_counter ))
    _patina_native_block_id="$$-$_patina_native_block_counter"
    _patina_native_input_recorded=0
    _patina_native_mkdir -p "$_patina_native_dir/blocks/$_patina_native_block_id"
    _patina_native_block_cwd=$PWD
    _patina_native_metadata cwd "$_patina_native_block_cwd"
    builtin local branch
    branch=$(command /usr/bin/git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=''
    _patina_native_metadata branch "$branch"
    _patina_native_metadata status editing

    # A starts the header on a fresh line. Two explicit chrome rows keep
    # four-point top/bottom gaps and the caption readable on a fixed VT grid.
    # B may repeat during ZLE redisplay. The block identity remains unchanged.
    builtin print -rnu $_patina_native_tty -- \
        $'\e]133;A;aid='"$_patina_native_block_id"$'\a\n\n'
    _patina_native_apply_prompt
    return 0
}

_patina_native_preexec() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    _patina_native_restore_prompt
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
    builtin local result=$?
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    _patina_native_completion_stop
    _patina_native_finish_block "$result"
    _patina_native_publish exited end
    return 0
}

_patina_native_publish() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local value="$1"$'\t'"$_patina_native_generation"$'\t'"$2"$'\t'"$_patina_native_block_id"
    [[ $value == $_patina_native_last_state ]] && return 0
    builtin local temporary="$_patina_native_dir/state.tmp.$$"
    builtin print -r -- "$value" > "$temporary" &&
        _patina_native_move -f "$temporary" "$_patina_native_dir/state" &&
        _patina_native_last_state=$value
}

_patina_native_receipt() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local value="$1"$'\t'"$2"
    [[ -n $3 ]] && value+=$'\t'"$3"
    builtin local temporary="$_patina_native_dir/receipt.tmp.$$"
    builtin print -r -- "$value" > "$temporary" &&
        _patina_native_move -f "$temporary" "$_patina_native_dir/receipt"
}

_patina_native_line_init() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    (( ++_patina_native_counter ))
    _patina_native_generation="$$-$_patina_native_counter"
    # Startup's one-shot precmd can precede user theme hooks in the first
    # captured hook list. Finalize after them and after existing ZLE init hooks.
    if [[ $PS1 != $_patina_native_marked_ps1 || $PS2 != $_patina_native_marked_ps2 ||
          -n $RPS1 || -n $RPS2 ]]; then
        _patina_native_apply_prompt
        builtin zle .reset-prompt
    fi
    if [[ $CONTEXT == start && $_patina_native_block_cwd != $PWD ]]; then
        _patina_native_block_cwd=$PWD
        _patina_native_metadata cwd "$PWD"
        builtin local branch
        branch=$(command /usr/bin/git -C "$PWD" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=''
        _patina_native_metadata branch "$branch"
    fi
    _patina_native_redraw
}

_patina_native_redraw() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    if [[ $CONTEXT != start ]]; then
        _patina_native_publish terminal "$CONTEXT"
    elif [[ -n $BUFFER ]]; then
        _patina_native_publish terminal start
    else
        _patina_native_publish ready start
    fi
}

_patina_native_line_finish() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    if [[ $CONTEXT == start ]]; then
        _patina_native_record_input "$BUFFER"
    fi
    _patina_native_publish running "$CONTEXT"
    # This also runs for blank input/cancellation, which have no preexec hook.
    # Theme/precmd/preexec functions see their own prompt values between edits.
    _patina_native_restore_prompt
}

_patina_native_byte_count() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local LC_ALL=C
    REPLY=${#1}
}

_patina_native_submit() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local request="$_patina_native_dir/request"
    builtin local consumed="$_patina_native_dir/consumed.$$"
    # A delayed duplicate trigger must not erase a receipt the app has yet to see.
    [[ -f $request && ! -L $request ]] || return 0
    _patina_native_move -f "$request" "$consumed" || return 1

    builtin local generation identifier payload descriptor reason REPLY
    builtin local -A metadata
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
        _patina_native_remove -f "$consumed"
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
# items-v1: repeated UTF-8 caret byte offset NUL, exact resulting buffer NUL.
# The app binds UUID to its draft revision and discards obsolete responses.

_patina_native_completion_initialize() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    # Preserve an initialized user completion system, including wrappers,
    # compdefs, styles and fpath. Bootstrap compsys only when none exists.
    if (( ! ${+functions[compdef]} || ! ${+_comps} )); then
        builtin autoload -Uz compinit
        compinit -i -D || return 0
    fi
    (( ${+functions[_main_complete]} )) || builtin autoload -Uz _main_complete
    {
        builtin zmodload zsh/zpty &&
        builtin zmodload -F zsh/files b:zf_mkdir b:zf_mv b:zf_rm &&
        builtin zf_mkdir -p "$_patina_native_dir/completions" &&
        _patina_native_completion_available=1
    }
    return 0
}

_patina_native_completion_noop() { return 0 }

_patina_native_completion_stop() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
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
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
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
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
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
    builtin local working=''
    builtin vared -i _patina_native_completion_noop \
        -f _patina_native_completion_noop working
}

# Populate dynamically scoped generation/identifier/payload/caret/character_caret
# and reason. Read only a finite regular file; no eval or shell expansion.
_patina_native_completion_read() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local descriptor REPLY
    builtin local -A metadata
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
        # The parent only routes a bounded, identified request. Full UTF-8,
        # dynamic-syntax and character-offset checks happen once in its worker
        # before anything reaches compsys. Avoid an iconv process on the real
        # interactive shell's ZLE path for every completion request.
        [[ ${2-} == route-only ]] && return 0
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
        builtin local -i low=0 high=${#payload} middle bytes wanted=10#$caret
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
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local destination="$_patina_native_dir/completions/$identifier"
    builtin local staging="$_patina_native_dir/completions/.pending-$identifier"
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
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local LC_ALL=en_US.UTF-8
    builtin local request="$_patina_native_dir/completion-request"
    builtin local consumed="$_patina_native_dir/completion-consumed.$$"
    [[ -f $request && ! -L $request ]] || return 0
    (( _patina_native_completion_available )) || return 0
    builtin zf_mv -f "$request" "$consumed" || return 1
    builtin local generation identifier='-' payload caret reason
    builtin local -i character_caret
    {
        if _patina_native_completion_read "$consumed" route-only; then
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
    builtin unset MENUSELECT
}

_patina_native_completion_worker_widget() {
    builtin emulate -L zsh -o no_aliases -o no_warn_create_global
    builtin local LC_ALL=en_US.UTF-8
    builtin local generation identifier='-' payload caret reason REPLY
    builtin local -i character_caret
    builtin local active="$_patina_native_dir/completion-active"
    builtin local request="$_patina_native_dir/completion-worker-request.$_patina_native_block_id"
    [[ -f $active && ! -L $active ]] || return 0
    # Claim by rename before reading. A newer request can then replace active
    # without the old reader deleting it after finishing its own payload.
    builtin zf_mv -f "$active" "$request" || return 0
    if ! _patina_native_completion_read "$request"; then
        _patina_native_completion_reject
        builtin zf_rm -f "$request"
        return 0
    fi
    builtin zf_rm -f "$request"
    builtin local destination="$_patina_native_dir/completions/$identifier"
    builtin local staging="$_patina_native_dir/completions/.pending-$identifier"
    [[ -e $destination ]] && return 0
    builtin zf_mkdir -p "$staging" || return 1
    builtin local packed_descriptor
    builtin local -i _patina_completion_matches=0 index count=0 total_bytes=0 truncated=0 bytes
    builtin local -A seen
    {
        builtin exec {packed_descriptor}> "$staging/items-v1" || return 1
        BUFFER=$payload
        CURSOR=$character_caret
        # Restore user completion options before ZLE parses the command. Doing
        # this inside the completion function is too late for alias expansion.
        builtin local option
        for option in aliases alwaystoend alwayslastprompt autolist automenu autonamedirs \
            autoparamkeys autoparamslash autoremoveslash bashautolist completealiases \
            completeinword globcomplete hashlistall listambiguous listbeep listpacked \
            listrowsfirst listtypes menucomplete recexact; do
            if [[ ${_patina_native_completion_options[$option]-off} == on ]]; then
                builtin setopt "$option"
            else
                builtin unsetopt "$option"
            fi
        done
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
            _patina_native_byte_count "$LBUFFER"
            builtin print -rnu $packed_descriptor -- "$REPLY"$'\0'"$BUFFER"$'\0'
        done
        builtin exec {packed_descriptor}>&-
        packed_descriptor=''
        builtin print -rn -- "$generation" > "$staging/generation"
        builtin print -rn -- "$identifier" > "$staging/identifier"
        builtin print -rn -- ok > "$staging/status"
        builtin print -rn -- '' > "$staging/reason"
        builtin print -rn -- "$count" > "$staging/count"
        builtin print -rn -- "$truncated" > "$staging/truncated"
        builtin zf_mv "$staging" "$destination"
    } always {
        [[ -n $packed_descriptor ]] && builtin exec {packed_descriptor}>&-
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
builtin autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init _patina_native_line_init
add-zle-hook-widget line-pre-redraw _patina_native_redraw
add-zle-hook-widget line-finish _patina_native_line_finish
# Reserve only the two transport sequences. Preserve the user's main keymap
# (including a custom map copied before this integration was loaded).
builtin bindkey -M main $'\e[99;1~' _patina_native_submit
builtin bindkey -M main $'\e[99;2~' _patina_native_complete
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
