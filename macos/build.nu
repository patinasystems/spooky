#!/usr/bin/env nu

# Build the macOS Spooky app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --arch: string = ""                # Optional architecture for a native-only GhosttyKit build
    --xcconfig: string = ""            # Optional build settings file
    --only-testing: string = ""        # Optional comma-separated target, suite, or test identifiers
    --test-parallelism: int = 0       # Optional Swift Testing concurrency limit; 0 keeps the default
    --build-dir: string = ""           # Optional isolated output directory
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let output_dir = if $build_dir == "" { ($env.FILE_PWD | path join "build-spooky") } else { ($build_dir | path expand) }

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    # Explicit --arch remains available for cross builds; local builds are native.
    let build_arch = if $arch == "" { (^uname -m | str trim) } else { $arch }
    let arch_args = [-arch $build_arch]
    let config_args = if $xcconfig == "" { [] } else { [-xcconfig ($xcconfig | path expand)] }
    let test_args = if $only_testing == "" { [] } else { $only_testing | split row "," | each { |id| $"-only-testing:($id)" } }
    let derived_args = [-derivedDataPath ($output_dir | path join "DerivedData")]

    # AppKit tests share a main event loop and process-wide native services.
    # Allow diagnostic runs to serialize them without relaxing test deadlines.
    let test_env = if $action == "test" and $test_parallelism > 0 {
        [$"TEST_RUNNER_SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH=($test_parallelism)"]
    } else { [] }
    # A serial Swift Testing runner is not enough if Xcode launches several
    # copies of the AppKit host. Honor the serial option at both levels.
    let runner_args = if $action == "test" and $test_parallelism == 1 {
        [-parallel-testing-enabled NO]
    } else { [] }
    # Opt-in real Spotlight coverage without forcing an index import on CI.
    let spotlight_fixture = ($env.SPOOKY_SPOTLIGHT_FIXTURE_PATH? | default "")
    let spotlight_env = if $action == "test" and $spotlight_fixture != "" {
        [$"TEST_RUNNER_SPOOKY_SPOTLIGHT_FIXTURE_PATH=($spotlight_fixture)"]
    } else { [] }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        ...$test_env
        ...$spotlight_env
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($output_dir)"
        ...$derived_args
        ...$arch_args
        ...$config_args
        ...$test_args
        ...$runner_args
        ...$skip_testing
        $action)
}
