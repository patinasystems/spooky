# Installed as .zshenv in the private pane directory. The terminal core selects
# the user's actual command and saves its effective ZDOTDIR before redirecting
# it here. No command, shell option, or user startup file is replaced.

'builtin' 'typeset' -g _patina_native_startup_directory="$PATINA_NATIVE_INPUT_DIR"
'builtin' 'typeset' +x _patina_native_startup_directory
'builtin' 'unset' PATINA_NATIVE_INPUT_DIR

if [[ ${SPOOKY_ZSH_ZDOTDIR+present} == present ]]; then
    'builtin' 'export' ZDOTDIR="$SPOOKY_ZSH_ZDOTDIR"
else
    'builtin' 'unset' ZDOTDIR
fi
'builtin' 'unset' SPOOKY_ZSH_ZDOTDIR

# Preserve an explicitly empty ZDOTDIR; only an unset one falls back to HOME.
# Source only this file. Zsh itself then reads the applicable global and
# user .zprofile, .zshrc, and .zlogin files with their normal RCS/login behavior.
if [[ -r "${ZDOTDIR-$HOME}/.zshenv" ]]; then
    'builtin' 'source' -- "${ZDOTDIR-$HOME}/.zshenv"
fi

if [[ -o interactive && -n $_patina_native_startup_directory ]]; then
    '_patina_native_deferred_init'() {
        'builtin' 'local' -A _patina_native_initial_options
        _patina_native_initial_options=("${(@kv)options[@]}")
        'builtin' 'emulate' -L zsh -o no_aliases
        'builtin' 'local' PATINA_NATIVE_INPUT_DIR="$_patina_native_startup_directory"
        'builtin' 'typeset' -ga precmd_functions
        precmd_functions=(${precmd_functions:#_patina_native_deferred_init})
        'builtin' 'unset' _patina_native_startup_directory
        if [[ -r "$PATINA_NATIVE_INPUT_DIR/native-input.zsh" ]] &&
           'builtin' 'source' -- "$PATINA_NATIVE_INPUT_DIR/native-input.zsh"; then
            # Zsh has already captured this prompt's hook array. Initialize the
            # first block now; subsequent prompts run the adapter at the tail.
            if (( ${+functions[_patina_native_precmd]} )); then
                '_patina_native_precmd'
            fi
        fi
        'builtin' 'unfunction' _patina_native_deferred_init
        return 0
    }
    'builtin' 'typeset' -ga precmd_functions
    precmd_functions+=(_patina_native_deferred_init)
else
    'builtin' 'unset' _patina_native_startup_directory
fi
