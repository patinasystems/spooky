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

    let arch_args = if $arch == "" { [] } else { [-arch $arch] }
    let config_args = if $xcconfig == "" { [] } else { [-xcconfig ($xcconfig | path expand)] }
    let test_args = if $only_testing == "" { [] } else { $only_testing | split row "," | each { |id| $"-only-testing:($id)" } }
    let derived_args = [-derivedDataPath ($output_dir | path join "DerivedData")]

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($output_dir)"
        ...$derived_args
        ...$arch_args
        ...$config_args
        ...$test_args
        ...$skip_testing
        $action)
}
